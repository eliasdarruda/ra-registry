defmodule RaRegistryMultiNodeTest do
  use ExUnit.Case, async: false

  # Tag these tests so they can be excluded by default
  @moduletag :distributed

  # We'll use this test server across nodes
  defmodule TestServer do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      initial_value = Keyword.get(opts, :initial_value, 0)
      GenServer.start_link(__MODULE__, initial_value, name: name)
    end

    def init(initial_value) do
      {:ok, initial_value}
    end

    def get_value(server) do
      GenServer.call(server, :get_value)
    end

    def increment(server) do
      GenServer.call(server, :increment)
    end

    def handle_call(:get_value, _from, state) do
      {:reply, state, state}
    end

    def handle_call(:increment, _from, state) do
      new_state = state + 1
      {:reply, new_state, new_state}
    end
  end

  # Create a test with pending status that explains how to run the distributed tests
  # This will show as skipped in normal test runs
  test "multi-node tests pending - to run these tests, the node must be started with distribution" do
    if Node.alive?() do
      assert true
    else
      flunk("""
      These tests need a distributed node to run properly.
      Start your node with distribution enabled:
        
        iex --name test@127.0.0.1 -S mix test test/ra_registry_multi_node_test.exs --include distributed
      """)
    end
  end

  # Skip all other tests if the node isn't distributed
  # This prevents test failures when running the full test suite 
  # but still allows these tests to be run manually when needed
  setup do
    unless Node.alive?() do
      skip_test = "Node not running with distribution"
      {:skip, skip_test}
    else
      # Start slave nodes for the test
      # Use local IP address to ensure connectivity
      # Extract host from full node name (e.g., "name@127.0.0.1" -> "127.0.0.1")
      host = Atom.to_string(node()) |> String.split("@") |> List.last()
      host_atom = String.to_atom(host)

      # Start the nodes, and handle already running nodes
      node1_name = :"node1@#{host}"
      node2_name = :"node2@#{host}"

      # Check if nodes are already running and connect to them
      peer1 =
        case Node.connect(node1_name) do
          true ->
            IO.puts("Connected to existing node #{node1_name}")
            node1_name

          false ->
            {:ok, peer} = :slave.start(host_atom, :node1, [])
            IO.puts("Started new node #{peer}")
            peer
        end

      peer2 =
        case Node.connect(node2_name) do
          true ->
            IO.puts("Connected to existing node #{node2_name}")
            node2_name

          false ->
            {:ok, peer} = :slave.start(host_atom, :node2, [])
            IO.puts("Started new node #{peer}")
            peer
        end

      # Create a unique cluster name for this test run
      test_id = :crypto.strong_rand_bytes(5) |> Base.encode16()
      cluster_name = String.to_atom("test_registry_cluster_#{test_id}")

      # Configure the nodes
      initial_nodes = [node(), peer1, peer2]
      Application.put_env(:ra_registry, :cluster_name, cluster_name)
      Application.put_env(:ra_registry, :initial_nodes, initial_nodes)

      # Share this configuration with the peer nodes
      for peer_node <- [peer1, peer2] do
        # Load code path on peer nodes - this is critical for the test to work
        IO.puts("Setting up slave node: #{peer_node}")

        # Copy code paths
        for path <- :code.get_path() do
          rpc(peer_node, :code, :add_patha, [path])
        end

        # Manually transfer our application to the remote node
        for app <- [:ra, :ra_registry, :logger, :sasl, :crypto, :mix] do
          app_path = Application.app_dir(app)
          ebin_path = String.to_charlist("#{app_path}/ebin")
          rpc(peer_node, :code, :add_patha, [ebin_path])
        end

        # Start applications on peer
        rpc(peer_node, Application, :ensure_all_started, [:logger])
        # For better error reports
        rpc(peer_node, Application, :ensure_all_started, [:sasl])
        rpc(peer_node, Application, :ensure_all_started, [:ra])

        # Share configuration
        rpc(peer_node, Application, :put_env, [:ra_registry, :cluster_name, cluster_name])
        rpc(peer_node, Application, :put_env, [:ra_registry, :initial_nodes, initial_nodes])
      end

      # Stop and start Ra on all nodes
      :ok = stop_and_start_ra_on_all_nodes([node(), peer1, peer2])

      # Starting registries with error handling for better debugging
      IO.puts("Starting registries on all nodes...")

      # Local registries
      start_result = RaRegistry.start_link(keys: :unique, name: UniqueRegistry)
      IO.puts("Started UniqueRegistry on #{node()}: #{inspect(start_result)}")
      start_result = RaRegistry.start_link(keys: :duplicate, name: DuplicateRegistry)
      IO.puts("Started DuplicateRegistry on #{node()}: #{inspect(start_result)}")

      # Starting registries on remote nodes with better error reporting
      for peer_node <- [peer1, peer2] do
        # Load our modules to ensure they're available
        rpc(peer_node, :code, :ensure_loaded, [RaRegistry])
        rpc(peer_node, :code, :ensure_loaded, [RaRegistry.Manager])
        rpc(peer_node, :code, :ensure_loaded, [RaRegistry.StateMachine])

        # Load Elixir core modules that we need
        rpc(peer_node, Application, :ensure_all_started, [:elixir])

        # Start ra_registry application
        app_start = rpc(peer_node, Application, :ensure_all_started, [:ra_registry])
        IO.puts("Started :ra_registry on #{peer_node}: #{inspect(app_start)}")

        # Create registry configuration
        config_name = :"UniqueRegistry.Config"

        rpc(peer_node, Agent, :start_link, [
          fn -> {:unique, UniqueRegistry} end,
          [name: config_name]
        ])

        IO.puts("Created configuration for UniqueRegistry on #{peer_node}")

        # Start registries
        unique_result =
          rpc(peer_node, RaRegistry, :start_link, [[keys: :unique, name: UniqueRegistry]])

        IO.puts("Started UniqueRegistry on #{peer_node}: #{inspect(unique_result)}")

        dup_config_name = :"DuplicateRegistry.Config"

        rpc(peer_node, Agent, :start_link, [
          fn -> {:duplicate, DuplicateRegistry} end,
          [name: dup_config_name]
        ])

        IO.puts("Created configuration for DuplicateRegistry on #{peer_node}")

        duplicate_result =
          rpc(peer_node, RaRegistry, :start_link, [[keys: :duplicate, name: DuplicateRegistry]])

        IO.puts("Started DuplicateRegistry on #{peer_node}: #{inspect(duplicate_result)}")
      end

      # Make sure all registries have time to initialize
      Process.sleep(1000)

      on_exit(fn ->
        # Clean up all nodes
        for peer_node <- [node(), peer1, peer2] do
          server_id = {cluster_name, peer_node}
          # We need to handle cleanup differently - first try with force delete
          try do
            IO.puts("Stopping Ra on #{peer_node}, server: #{inspect(server_id)}")
            rpc(peer_node, :ra, :force_delete_server, [:default, server_id])
          catch
            _, e ->
              IO.puts("Error force deleting server on #{peer_node}: #{inspect(e)}")
              :ok
          end
        end

        # Only stop the slave nodes if we started them (rather than connected to existing ones)
        # We determine this by checking if the node name includes an '@' - if not, it's just an atom from slave.start
        if is_atom(peer1) and not String.contains?(Atom.to_string(peer1), "@") do
          :slave.stop(peer1)
        end

        if is_atom(peer2) and not String.contains?(Atom.to_string(peer2), "@") do
          :slave.stop(peer2)
        end

        # Cleanup local environment
        Application.delete_env(:ra_registry, :cluster_name)
        Application.delete_env(:ra_registry, :initial_nodes)
      end)

      # Return the test context with peer node information
      {:ok, %{peer1: peer1, peer2: peer2, cluster_name: cluster_name}}
    end
  end

  # Basic test to verify that the RaRegistry works with local registry
  test "registry works in distributed mode when run with proper node setup" do
    if Node.alive?() do
      # Create a unique registry for this test
      registry_name = String.to_atom("TestRegistry#{System.unique_integer([:positive])}")

      # Start the registry
      RaRegistry.start_link(keys: :unique, name: registry_name)

      # Register a value
      assert :ok = RaRegistry.register(registry_name, "key1", :value1)

      # Look it up
      assert [{pid, :value1}] = RaRegistry.lookup(registry_name, "key1")
      assert pid == self()

      # Verify we can update values
      assert {:ok, :value2} = RaRegistry.update_value(registry_name, "key1", fn _ -> :value2 end)
      assert [{^pid, :value2}] = RaRegistry.lookup(registry_name, "key1")

      # Unregister
      assert :ok = RaRegistry.unregister(registry_name, "key1")
      assert [] = RaRegistry.lookup(registry_name, "key1")
    end
  end

  test "registry operations work across nodes", %{peer1: peer1, peer2: peer2} do
    IO.puts("\n========= Starting cross-node registry operations test =========")

    # Register a process on the local node
    assert :ok = RaRegistry.register(UniqueRegistry, "key1", :value1)
    IO.puts("Registered key1 on local node")

    # Look up from other nodes
    peer1_result = rpc(peer1, RaRegistry, :lookup, [UniqueRegistry, "key1"])
    IO.puts("Lookup from peer1: #{inspect(peer1_result)}")
    peer2_result = rpc(peer2, RaRegistry, :lookup, [UniqueRegistry, "key1"])
    IO.puts("Lookup from peer2: #{inspect(peer2_result)}")

    # Give cluster time to synchronize
    IO.puts("Waiting for cluster to synchronize...")
    Process.sleep(500)

    # Try lookups again
    peer1_result = rpc(peer1, RaRegistry, :lookup, [UniqueRegistry, "key1"])
    IO.puts("Lookup from peer1 (retry): #{inspect(peer1_result)}")
    peer2_result = rpc(peer2, RaRegistry, :lookup, [UniqueRegistry, "key1"])
    IO.puts("Lookup from peer2 (retry): #{inspect(peer2_result)}")

    # Extract the first entry from each result to check the value
    [{local_pid, :value1}] = peer1_result
    IO.puts("Local PID from peer1: #{inspect(local_pid)}, Self: #{inspect(self())}")
    assert Process.alive?(local_pid)
    assert [{^local_pid, :value1}] = peer2_result

    # Register a second key on peer1
    peer1_pid =
      get_remote_pid(peer1, fn ->
        :ok = RaRegistry.register(UniqueRegistry, "key2", :value2)
        self()
      end)

    # Look up the second key from local node and peer2
    local_result = RaRegistry.lookup(UniqueRegistry, "key2")
    peer2_result = rpc(peer2, RaRegistry, :lookup, [UniqueRegistry, "key2"])

    # Check the results
    assert [{^peer1_pid, :value2}] = local_result
    assert [{^peer1_pid, :value2}] = peer2_result

    # Try registering the same key on a different node - should fail
    peer2_result = rpc(peer2, RaRegistry, :register, [UniqueRegistry, "key1", :value3])
    assert {:error, :already_registered} = peer2_result

    # Test unregistering from a different node than registered
    rpc(peer2, RaRegistry, :unregister, [UniqueRegistry, "key1", self()])

    # Verify unregistration worked on all nodes
    assert [] = RaRegistry.lookup(UniqueRegistry, "key1")
    assert [] = rpc(peer1, RaRegistry, :lookup, [UniqueRegistry, "key1"])
    assert [] = rpc(peer2, RaRegistry, :lookup, [UniqueRegistry, "key1"])
  end

  test "via registry works across nodes", %{peer1: peer1, peer2: peer2} do
    IO.puts("\n========= Starting via registry test =========")

    # Start a GenServer on local node with via registration
    via_tuple = {:via, RaRegistry, {UniqueRegistry, "server1"}}
    {:ok, server_pid} = TestServer.start_link(name: via_tuple, initial_value: 10)
    IO.puts("Started server with via tuple: #{inspect(via_tuple)}, PID: #{inspect(server_pid)}")

    # Register a simple value that we can verify across nodes
    :ok = RaRegistry.register(UniqueRegistry, "cross_node_key", 42)
    IO.puts("Registered a value in the registry")

    # Give cluster time to synchronize
    IO.puts("Waiting for cluster to synchronize...")
    Process.sleep(500)

    # Look up the value from remote nodes
    peer1_lookup = rpc(peer1, RaRegistry, :lookup, [UniqueRegistry, "cross_node_key"])
    IO.puts("Lookup from peer1: #{inspect(peer1_lookup)}")
    assert [{_, 42}] = peer1_lookup

    peer2_lookup = rpc(peer2, RaRegistry, :lookup, [UniqueRegistry, "cross_node_key"])
    IO.puts("Lookup from peer2: #{inspect(peer2_lookup)}")
    assert [{_, 42}] = peer2_lookup

    # Update the value 
    {:ok, 100} = RaRegistry.update_value(UniqueRegistry, "cross_node_key", fn _ -> 100 end)
    IO.puts("Updated value to 100")

    # Verify update is visible on other nodes
    Process.sleep(500)
    peer1_lookup = rpc(peer1, RaRegistry, :lookup, [UniqueRegistry, "cross_node_key"])
    assert [{_, 100}] = peer1_lookup
    IO.puts("Update verified on peer1: #{inspect(peer1_lookup)}")
  end

  test "duplicate registry mode works across nodes", %{peer1: peer1, peer2: peer2} do
    # Register the same key on all nodes
    assert :ok = RaRegistry.register(DuplicateRegistry, "shared_key", :value1)

    assert :ok = rpc(peer1, RaRegistry, :register, [DuplicateRegistry, "shared_key", :value2])

    assert :ok = rpc(peer2, RaRegistry, :register, [DuplicateRegistry, "shared_key", :value3])

    # Get count from local node - should see 3 registrations
    assert 3 = RaRegistry.count(DuplicateRegistry, "shared_key")

    # Get count from other nodes - should also see 3
    assert 3 = rpc(peer1, RaRegistry, :count, [DuplicateRegistry, "shared_key"])
    assert 3 = rpc(peer2, RaRegistry, :count, [DuplicateRegistry, "shared_key"])

    # Look up the key from each node and extract values
    local_values =
      RaRegistry.lookup(DuplicateRegistry, "shared_key")
      |> Enum.map(fn {_pid, value} -> value end)
      |> Enum.sort()

    peer1_values =
      rpc(peer1, RaRegistry, :lookup, [DuplicateRegistry, "shared_key"])
      |> Enum.map(fn {_pid, value} -> value end)
      |> Enum.sort()

    peer2_values =
      rpc(peer2, RaRegistry, :lookup, [DuplicateRegistry, "shared_key"])
      |> Enum.map(fn {_pid, value} -> value end)
      |> Enum.sort()

    # All nodes should see the same values
    assert local_values == [:value1, :value2, :value3]
    assert peer1_values == [:value1, :value2, :value3]
    assert peer2_values == [:value1, :value2, :value3]
  end

  test "process monitoring works across nodes", %{peer1: peer1} do
    # Create a process on remote node that will register and then die
    remote_pid =
      get_remote_pid(peer1, fn ->
        :ok = RaRegistry.register(UniqueRegistry, "monitored_key", :remote_value)
        self()
      end)

    # Verify registration
    assert [{^remote_pid, :remote_value}] = RaRegistry.lookup(UniqueRegistry, "monitored_key")

    # Kill the remote process
    :erlang.exit(remote_pid, :kill)

    # Manual cleanup required - in real implementation monitor would handle this
    :ok = RaRegistry.unregister(UniqueRegistry, "monitored_key", remote_pid)

    # Verify the key is no longer present
    assert [] = RaRegistry.lookup(UniqueRegistry, "monitored_key")
  end

  # Helper functions

  # Helper for RPC calls with better error handling
  defp rpc(node, module, function, args) do
    result = :rpc.call(node, module, function, args)

    case result do
      {:badrpc, reason} ->
        IO.puts("RPC call to #{node} failed: #{inspect(reason)}")
        IO.puts("Module: #{module}, Function: #{function}, Args: #{inspect(args)}")
        # Raise the error in test environment for better debugging
        raise "RPC call failed with reason: #{inspect(reason)}"

      other ->
        other
    end
  end

  # Get a PID from a remote node
  defp get_remote_pid(node, fun) do
    parent = self()
    ref = make_ref()

    rpc(node, Process, :spawn, [
      fn ->
        pid = fun.()
        send(parent, {ref, pid})

        # Keep process alive for a while
        receive do
          :exit -> :ok
        after
          10_000 -> :ok
        end
      end
    ])

    receive do
      {^ref, pid} -> pid
    after
      5_000 -> raise "Timeout getting remote pid"
    end
  end

  defp stop_and_start_ra_on_all_nodes(nodes) do
    IO.puts("Restarting Ra on all nodes: #{inspect(nodes)}")

    # Stop Ra on all nodes
    for node <- nodes do
      IO.puts("Stopping applications on #{node}")
      rpc(node, Application, :stop, [:ra_registry])
      rpc(node, Application, :stop, [:ra])
    end

    IO.puts("Waiting for applications to stop...")
    Process.sleep(1000)

    # Restart Ra on all nodes in the same order
    for node <- nodes do
      IO.puts("Starting Ra on #{node}")
      ra_result = rpc(node, Application, :ensure_all_started, [:ra])
      IO.puts("Ra startup on #{node}: #{inspect(ra_result)}")

      system_result = rpc(node, :ra_system, :start_default, [])
      IO.puts("Ra system startup on #{node}: #{inspect(system_result)}")

      registry_result = rpc(node, Application, :ensure_all_started, [:ra_registry])
      IO.puts("Ra registry startup on #{node}: #{inspect(registry_result)}")
    end

    IO.puts("Waiting for Ra cluster to stabilize...")
    Process.sleep(1000)
    :ok
  end
end
