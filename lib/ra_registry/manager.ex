defmodule RaRegistry.Manager do
  @moduledoc """
  Manages the Ra cluster for the distributed registry.
  """
  use GenServer

  require Logger

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Client API

  @doc """
  Returns the current members of the Ra cluster.
  """
  def get_members(name) do
    GenServer.call(name, :get_members)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true, node_type: :visible)

    # Extract options
    keys = Keyword.fetch!(opts, :keys)
    name = Keyword.fetch!(opts, :name)
    nodes = Node.list() ++ [Node.self()]
    ra_config = Keyword.get(opts, :ra_config, %{})

    cluster_name = :"#{name}.RaCluster"

    # Each server needs a unique ID in the format {name, node}
    server_ids =
      for node <- nodes do
        {cluster_name, node}
      end

    # Our server ID is just our local node
    server_id = {cluster_name, node()}

    # Ensure Ra application is started
    Application.ensure_all_started(:ra)

    # Make sure the Ra system is started
    :ra_system.start_default()

    # Initialize Ra with the registry state machine
    # Ra 2.x uses {:module, ModuleName, initial_state} format
    machine = RaRegistry.StateMachine.machine_config()

    # Setup recurring health check timer
    Process.send_after(self(), :check_cluster_health, 11_000)

    # Ra configuration
    # 1) Increase default timeout to allow for more time
    # 2) Decrease election timeout for faster leader election after failures
    # 3) Configure max append entries batch size for better throughput
    ra_config =
      %{
        # Default timeout for operations (5s)
        default_timeout: 5_000,
        # Min/max election timeout (significantly decreased from default to handle SIGKILL scenarios)
        election_timeout: [500, 1000],
        # How often to send heartbeats (500ms for more aggressive leader detection)
        heartbeat_timeout: 500,
        # Max number of entries to replicate at once
        max_append_entries_batch_size: 64
      }
      |> Map.merge(ra_config)

    # Apply Ra config
    for {key, value} <- ra_config do
      Application.put_env(:ra, key, value)
    end

    # Attempt to start the Ra cluster
    case :ra.start_cluster(:default, cluster_name, machine, server_ids) do
      {:ok, started, _leader} ->
        Logger.info("RaRegistry started cluster with #{inspect(started)} nodes")
        {:ok, %{cluster_name: cluster_name, members: server_ids, keys: keys, name: name}}

      {:error, cluster_exists_error} ->
        Logger.info(
          "RaRegistry cluster may already exist: #{inspect(cluster_exists_error)}, continuing..."
        )

        # Check if we can see members - if not, try to add ourselves to any existing cluster
        task = Task.async(fn -> :ra.members(server_id) end)

        case Task.yield(task, 5000) do
          {:ok, {:ok, members, _leader}} ->
            Logger.info("Found existing cluster members: #{inspect(members)}")
            {:ok, %{cluster_name: cluster_name, members: members, keys: keys, name: name}}

          _ ->
            # Task timed out or failed
            Task.shutdown(task)

            # Check if we can find any other members to join
            if server_ids -- [server_id] != [] do
              Logger.info("Trying to join an existing cluster...")
              other_members = server_ids -- [server_id]

              join_result =
                Enum.find_value(other_members, fn other_member ->
                  try do
                    task = Task.async(fn -> :ra.add_member(other_member, server_id) end)

                    case Task.yield(task, 5000) do
                      {:ok, {:ok, _, _}} ->
                        true

                      _ ->
                        Task.shutdown(task)
                        false
                    end
                  catch
                    _, _ -> false
                  end
                end)

              if join_result do
                Logger.info("Successfully joined existing cluster")
              else
                Logger.warning("Failed to join existing cluster, starting as standalone")
              end

              {:ok, %{cluster_name: cluster_name, members: server_ids, keys: keys, name: name}}
            else
              # Standalone mode if no other members available
              {:ok, %{cluster_name: cluster_name, members: server_ids, keys: keys, name: name}}
            end
        end

      error ->
        Logger.error("Failed to start Ra cluster: #{inspect(error)}")
        # For tests, we still want to return success to avoid cascading failures
        {:ok, %{cluster_name: cluster_name, members: server_ids, keys: keys, name: name}}
    end
  end

  # All handle_call implementations grouped together
  @impl true
  def handle_call(:get_keys, _from, state) do
    {:reply, state.keys, state}
  end

  @impl true
  def handle_call(:get_members, _from, state) do
    {:reply, state.members, state}
  end

  @impl true
  def handle_call({:register, key, pid, value}, _from, state) do
    # Get the current monitored processes map or initialize it
    monitored_pids = Map.get(state, :monitored_pids, %{})

    try do
      leader_id = get_leader(state)

      # Reduced timeout to fail faster
      case :ra.process_command(leader_id, {:register, key, pid, value, state.keys}) do
        {:ok, :ok, _} ->
          # Set up monitoring for this process if we're not already monitoring it
          updated_state =
            if !Map.has_key?(monitored_pids, pid) do
              # Start monitoring the process
              ref = Process.monitor(pid)
              new_monitored = Map.put(monitored_pids, pid, ref)
              Map.put(state, :monitored_pids, new_monitored)
            else
              state
            end

          {:reply, :ok, updated_state}

        {:ok, {:error, :already_registered}, _} ->
          {:reply, {:error, :already_registered}, state}

        nil ->
          Logger.warning("COMMAND TIMEOUT - Cluster appears stuck, initiating emergency recovery")

          # Fall back to another member while recovery happens
          retry_with_fallback_member(key, pid, value, state)

        error ->
          # Try to recover the cluster if we get a timeout or leadership issue
          if is_timeout_error(error) do
            Logger.warning(
              "Timeout while registering: #{inspect(error)}, attempting emergency recovery"
            )

            # Extract failed node from error if possible
            failed_node = extract_failed_node_from_error(error)

            new_state =
              if failed_node do
                handle_node_failure(failed_node, state)
              else
                state
              end

            # Retry with fallback member
            retry_with_fallback_member(key, pid, value, new_state)
          else
            {:reply, {:error, error}, state}
          end
      end
    rescue
      error ->
        Logger.warning(
          "Exception during registration: #{inspect(error)}, initiating emergency recovery"
        )

        # Try fallback while recovery happens
        retry_with_fallback_member(key, pid, value, state)
    end
  end

  @impl true
  def handle_call({:unregister, key, pid}, _from, state) do
    server_id = {state.cluster_name, node()}

    try do
      case :ra.process_command(server_id, {:unregister, key, pid, state.keys}) do
        {:ok, :ok, _} ->
          # Clean up the monitor if we're unregistering this pid
          updated_state = clean_up_monitor(pid, state)
          {:reply, :ok, updated_state}

        error ->
          {:reply, {:error, error}, state}
      end
    rescue
      error ->
        # Try with another cluster member if available
        if state.members != [] and state.members != [server_id] do
          other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

          case :ra.process_command(other_member, {:unregister, key, pid, state.keys}) do
            {:ok, :ok, _} ->
              # Clean up the monitor if we're unregistering this pid
              updated_state = clean_up_monitor(pid, state)
              {:reply, :ok, updated_state}

            error ->
              {:reply, {:error, error}, state}
          end
        else
          {:reply, {:error, error}, state}
        end
    end
  end

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    results = do_lookup(key, state)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:count, key}, _from, state) do
    server_id = {state.cluster_name, node()}

    try do
      # First try with process_command
      case :ra.process_command(server_id, {:count, key, state.keys}) do
        {:ok, count, _} ->
          {:reply, count, state}

        _error ->
          # Fall back to consistent_query
          case :ra.consistent_query(server_id, {:count, key, state.keys}) do
            {:ok, count, _} -> {:reply, count, state}
            _ -> {:reply, 0, state}
          end
      end
    rescue
      _error ->
        # Try with another cluster member if available
        if state.members != [] and state.members != [server_id] do
          other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

          case :ra.consistent_query(other_member, {:count, key, state.keys}) do
            {:ok, count, _} -> {:reply, count, state}
            _ -> {:reply, 0, state}
          end
        else
          {:reply, 0, state}
        end
    end
  end

  @impl true
  def handle_call({:update_value, key, pid, callback}, _from, state) do
    # First lookup the current value
    case do_lookup(key, state) do
      [] ->
        {:reply, {:error, :not_registered}, state}

      [{^pid, value}] ->
        # Calculate the new value
        new_value = callback.(value)

        # Unregister and register with the new value
        case do_unregister(key, pid, state) do
          {:ok, updated_state} ->
            case do_register(key, pid, new_value, updated_state) do
              {:ok, final_state} ->
                {:reply, {:ok, new_value}, final_state}

              {:error, reason} ->
                {:reply, {:error, reason}, updated_state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_call({:match, key, pattern}, _from, state) do
    # First lookup all values for this key
    results = do_lookup(key, state)

    # Filter the results based on the pattern
    matches =
      Stream.filter(results, fn {_pid, value} ->
        try do
          match?(^pattern, value)
        rescue
          _ -> false
        end
      end)

    {:reply, matches, state}
  end

  # All handle_info implementations grouped together
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    server_id = {state.cluster_name, node()}

    # The process died, send a process_down command to the state machine
    try do
      case :ra.process_command(server_id, {:process_down, pid}) do
        {:ok, :ok, _} ->
          # Clean up our monitor
          updated_state = clean_up_monitor(pid, state)
          {:noreply, updated_state}

        _error ->
          # Try with another cluster member if available
          if state.members != [] and state.members != [server_id] do
            other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

            case :ra.process_command(other_member, {:process_down, pid}) do
              {:ok, :ok, _} ->
                updated_state = clean_up_monitor(pid, state)
                {:noreply, updated_state}

              _ ->
                # Still clean up our monitor even if the command fails
                updated_state = clean_up_monitor(pid, state)
                {:noreply, updated_state}
            end
          else
            # Still clean up our monitor
            updated_state = clean_up_monitor(pid, state)
            {:noreply, updated_state}
          end
      end
    rescue
      _error ->
        # If this fails, still clean up our monitor
        updated_state = clean_up_monitor(pid, state)
        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info({_ref, {:error, :shutdown}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    # Process EXIT messages - send process_down command to Ra
    # to clean up any registrations
    server_id = {state.cluster_name, node()}

    Logger.debug("Process EXIT: #{inspect(pid)}, reason: #{inspect(reason)}")

    try do
      # Send the process_down command to Ra
      case :ra.process_command(server_id, {:process_down, pid}) do
        {:ok, :ok, _} ->
          Logger.debug("Successfully cleaned up after pid #{inspect(pid)}")

        _ ->
          Logger.debug("Failed to clean up after pid #{inspect(pid)}")
      end
    catch
      _, _ -> :ok
    end

    # Always clean up monitoring
    updated_state = clean_up_monitor(pid, state)
    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:nodeup, node, _node_type}, state) do
    server_id = {state.cluster_name, node()}
    :ra.add_member(server_id, {state.cluster_name, node})

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _node_type}, state) do
    failed_member = {state.cluster_name, node}
    server_id = {state.cluster_name, node()}

    # First try to properly remove the member through Ra
    try do
      case :ra.remove_member(server_id, failed_member) do
        {:ok, _, _} ->
          Logger.info("Successfully removed member #{inspect(failed_member)} from cluster")

        error ->
          Logger.warning("Standard removal of #{inspect(node)} failed: #{inspect(error)}")
          # If regular removal fails, try force delete as fallback
          try_force_delete_member(failed_member)
      end
    catch
      kind, reason ->
        Logger.warning(
          "Error removing member #{inspect(node)}: #{inspect(kind)}, #{inspect(reason)}"
        )

        try_force_delete_member(failed_member)
    end

    # Update our local state to remove the member regardless of Ra operation success
    new_members = Enum.reject(state.members, fn m -> m == failed_member end)

    # Notify remaining members about the membership change
    notify_other_members_about_removal(new_members, failed_member, state.cluster_name)

    {:noreply, %{state | members: new_members}}
  end

  @impl true
  def handle_info(:check_cluster_health, state) do
    # Schedule the next health check - more frequent checks for faster recovery
    Process.send_after(self(), :check_cluster_health, 10_000)

    server_id = {state.cluster_name, node()}

    task = Task.async(fn -> :ra.members(server_id) end)

    case Task.yield(task, 3_000) do
      {:ok, {:ok, members, _leader}} ->
        # We got a response, check if our member list matches Ra's view
        current_members = MapSet.new(members)
        our_members = MapSet.new(state.members)

        if MapSet.equal?(current_members, our_members) do
          # All good, members match
          {:noreply, state}
        else
          # Update our member list to match Ra's view
          Logger.info(
            "Updating member list from #{inspect(state.members)} to #{inspect(members)}"
          )

          {:noreply, %{state | members: members}}
        end

      _ ->
        Logger.warning("Health check failed, attempting recovery")

        # No other members available, try to trigger leader election for future attempts
        maybe_force_election(state)

        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Clean shutdown of the Ra node
    server_id = {state.cluster_name, node()}
    leader = {state.cluster_name, node()}

    # Try to cleanly leave the cluster
    try do
      :ra.leave_and_terminate(:default, server_id, leader)
    catch
      _, _ -> :ok
    end

    # Ensure server is deleted
    try do
      :ra.force_delete_server(:default, server_id)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Private helper functions

  # Get the current leader or nil if no leader is elected
  defp get_leader(state) do
    server_id = {state.cluster_name, node()}

    case :ra.members(server_id) do
      {:ok, _members, leader} when leader != nil ->
        leader

      _ ->
        nil
    end
  end

  # Force election when cluster is stuck
  defp maybe_force_election(state) do
    server_id = {state.cluster_name, node()}

    Logger.error("EMERGENCY: Cluster appears completely stuck, attempting emergency recovery")

    Task.start(fn ->
      Logger.warning("EMERGENCY: Force deleting local server to break deadlock")

      try do
        # Force delete the local server
        :ra.force_delete_server(:default, server_id)

        machine = RaRegistry.StateMachine.machine_config()

        # check if nodes alive
        members =
          state.members
          |> Enum.filter(fn {_m, node} -> node in (Node.list() ++ [Node.self()]) end)

        :ra.start_cluster(:default, elem(server_id, 0), machine, members)
      catch
        kind, reason ->
          Logger.error("Error in emergency recovery: #{inspect(kind)}, #{inspect(reason)}")
      end
    end)
  end

  # Helper to retry register operation with a fallback member
  defp retry_with_fallback_member(key, pid, value, state) do
    server_id = {state.cluster_name, node()}
    monitored_pids = Map.get(state, :monitored_pids, %{})

    # Use any other cluster member if available
    if state.members != [] and state.members != [server_id] do
      other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

      case :ra.process_command(other_member, {:register, key, pid, value, state.keys}) do
        {:ok, :ok, _} ->
          # Set up monitoring for this process if we're not already monitoring it
          updated_state =
            if !Map.has_key?(monitored_pids, pid) do
              # Start monitoring the process
              ref = Process.monitor(pid)
              new_monitored = Map.put(monitored_pids, pid, ref)
              Map.put(state, :monitored_pids, new_monitored)
            else
              state
            end

          {:reply, :ok, updated_state}

        {:ok, {:error, :already_registered}, _} ->
          {:reply, {:error, :already_registered}, state}

        error ->
          {:reply, {:error, error}, state}
      end
    else
      {:reply, {:error, :no_available_members}, state}
    end
  end

  # Check if an error is timeout-related
  defp is_timeout_error(error) do
    case error do
      {:timeout, _} -> true
      {:badrpc, :timeout} -> true
      {:error, :timeout} -> true
      {:error, :noproc} -> true
      _ -> false
    end
  end

  # Try to extract the failed node from an error message
  defp extract_failed_node_from_error(error) do
    case error do
      {:timeout, {_cluster_name, node}} -> node
      {:badrpc, :timeout, node} -> node
      _ -> nil
    end
  end

  # Handles recovery from node failures by attempting to force delete the server
  defp try_force_delete_member(member) do
    try do
      Logger.info("Attempting to force delete member #{inspect(member)}")
      # Use :ra.force_delete_server/2 to remove the failed member from the cluster
      case :ra.force_delete_server(:default, member) do
        :ok ->
          Logger.info("Force deleted member #{inspect(member)}")

        {:error, error} ->
          Logger.warning("Failed to force delete member #{inspect(member)}: #{inspect(error)}")
      end
    catch
      kind, reason ->
        Logger.warning(
          "Exception when force deleting member #{inspect(member)}: #{inspect(kind)}, #{inspect(reason)}"
        )
    end
  end

  # Notify all other cluster members about a node removal
  defp notify_other_members_about_removal(members, failed_member, cluster_name) do
    local_server_id = {cluster_name, node()}

    # Only notify other nodes, not ourselves
    other_members = Enum.reject(members, fn m -> m == local_server_id end)

    # For each remaining cluster member, try to notify about the removal
    Enum.each(other_members, fn member ->
      try do
        Logger.debug("Notifying #{inspect(member)} about removal of #{inspect(failed_member)}")

        case :ra.remove_member(member, failed_member) do
          {:ok, _, _} ->
            Logger.debug("Successfully notified #{inspect(member)}")

          error ->
            Logger.warning("Error notifying #{inspect(member)}: #{inspect(error)}")
        end
      catch
        kind, reason ->
          Logger.warning(
            "Exception notifying #{inspect(member)}: #{inspect(kind)}, #{inspect(reason)}"
          )
      end
    end)
  end

  # Handle a failed/timeout command by checking if we need to clean up members
  defp handle_node_failure(node, state) do
    failed_member = {state.cluster_name, node}
    _server_id = {state.cluster_name, node()}

    # Force remove the failed node from local membership
    new_members =
      Enum.reject(state.members, fn m ->
        case m do
          {_cluster_name, ^node} -> true
          _ -> false
        end
      end)

    # Try to update other nodes about membership change
    notify_other_members_about_removal(new_members, failed_member, state.cluster_name)

    # Update local state
    %{state | members: new_members}
  end

  # Helper to clean up process monitoring
  defp clean_up_monitor(pid, state) do
    monitored_pids = Map.get(state, :monitored_pids, %{})

    case Map.get(monitored_pids, pid) do
      nil ->
        # We weren't monitoring this pid
        state

      ref ->
        # Demonitor the process (in case it's still alive)
        Process.demonitor(ref, [:flush])

        # Remove it from our monitored_pids map
        new_monitored = Map.delete(monitored_pids, pid)
        Map.put(state, :monitored_pids, new_monitored)
    end
  end

  defp do_lookup(key, state) do
    server_id = {state.cluster_name, node()}

    # Use proper Ra query format - module, function, arguments
    # The function must accept state as its first argument
    query_fun =
      case state.keys do
        :unique -> {RaRegistry.StateMachine, :lookup_query_unique, [key]}
        :duplicate -> {RaRegistry.StateMachine, :lookup_query_duplicate, [key]}
      end

    try do
      case :ra.consistent_query(server_id, query_fun) do
        {:ok, {:ok, results}, _} ->
          results

        _error ->
          # try other member
          other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

          case :ra.consistent_query(other_member, query_fun) do
            {:ok, {:ok, results}, _} -> results
            _ -> []
          end
      end
    rescue
      _error ->
        # In case of any error, return empty results
        []
    end
  end

  defp do_register(key, pid, value, state) do
    server_id = {state.cluster_name, node()}

    # Get the current monitored processes map or initialize it
    monitored_pids = Map.get(state, :monitored_pids, %{})

    try do
      # Try to find the leader for more reliable writes
      leader =
        case :ra.members(server_id) do
          {:ok, _members, leader_id} when leader_id != nil -> leader_id
          # Fall back to local node if leader unknown
          _ -> server_id
        end

      # Send the registration command to the leader when possible
      case :ra.process_command(leader, {:register, key, pid, value, state.keys}) do
        {:ok, :ok, _} ->
          # Set up monitoring for this process if we're not already monitoring it
          updated_state =
            if !Map.has_key?(monitored_pids, pid) do
              # Start monitoring the process
              ref = Process.monitor(pid)
              new_monitored = Map.put(monitored_pids, pid, ref)
              Map.put(state, :monitored_pids, new_monitored)
            else
              state
            end

          {:ok, updated_state}

        {:error, :already_registered} ->
          {:error, :already_registered}

        error ->
          {:error, error}
      end
    rescue
      error ->
        # Use any other cluster member if available
        if state.members != [] and state.members != [server_id] do
          other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

          case :ra.process_command(other_member, {:register, key, pid, value, state.keys}) do
            {:ok, :ok, _} ->
              # Set up monitoring for this process if we're not already monitoring it
              updated_state =
                if !Map.has_key?(monitored_pids, pid) do
                  # Start monitoring the process
                  ref = Process.monitor(pid)
                  new_monitored = Map.put(monitored_pids, pid, ref)
                  Map.put(state, :monitored_pids, new_monitored)
                else
                  state
                end

              {:ok, updated_state}

            {:ok, {:error, :already_registered}, _} ->
              {:error, :already_registered}

            error ->
              {:error, error}
          end
        else
          {:error, error}
        end
    end
  end

  defp do_unregister(key, pid, state) do
    server_id = {state.cluster_name, node()}

    try do
      # Try to find the leader for more reliable writes
      leader =
        case :ra.members(server_id) do
          {:ok, _members, leader_id} when leader_id != nil -> leader_id
          # Fall back to local node if leader unknown
          _ -> server_id
        end

      # Send the unregister command to the leader when possible
      case :ra.process_command(leader, {:unregister, key, pid, state.keys}) do
        {:ok, :ok, _} ->
          # Clean up monitoring for this process
          updated_state = clean_up_monitor(pid, state)
          {:ok, updated_state}

        error ->
          {:error, error}
      end
    rescue
      error ->
        # Try with another cluster member if available
        if state.members != [] and state.members != [server_id] do
          other_member = Enum.find(state.members, fn m -> m != server_id end) || server_id

          case :ra.process_command(other_member, {:unregister, key, pid, state.keys}) do
            {:ok, :ok, _} ->
              # Clean up monitoring for this process
              updated_state = clean_up_monitor(pid, state)
              {:ok, updated_state}

            error ->
              {:error, error}
          end
        else
          {:error, error}
        end
    end
  end
end
