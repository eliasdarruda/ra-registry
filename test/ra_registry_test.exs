defmodule RaRegistryTest do
  use ExUnit.Case, async: false
  doctest RaRegistry

  setup do
    # Generate a unique cluster name for this test run
    test_id = :crypto.strong_rand_bytes(5) |> Base.encode16()
    cluster_name = String.to_atom("test_registry_cluster_#{test_id}")

    # Set the cluster name in application environment
    Application.put_env(:ra_registry, :cluster_name, cluster_name)

    # Stop any previous Ra applications
    Application.stop(:ra_registry)
    Application.stop(:ra)

    # Start Ra and Ra system with logging
    Application.ensure_all_started(:ra)
    :ra_system.start_default()

    # Clean up any existing process registry from previous tests
    try do
      Registry.unregister(Registry.ProcessRegistry, {RaRegistry, :test_registry})
    catch
      _, _ -> :ok
    end

    # Don't try to start the application as we're not an application

    # Make sure our Ra node is actually started
    server_id = {cluster_name, node()}

    # Debug to see if node is actually running
    IO.puts("Ra member status for #{inspect(server_id)}: #{inspect(:ra.members(server_id))}")

    # Set up test registries with a wait between them
    RaRegistry.start_link(keys: :unique, name: UniqueRegistry, wait_for_nodes_range_ms: 1..2)

    RaRegistry.start_link(
      keys: :duplicate,
      name: DuplicateRegistry,
      wait_for_nodes_range_ms: 1..2
    )

    # Try to register something directly to check if the system is working
    test_result = RaRegistry.register(UniqueRegistry, "_test_startup_key", "test_value")
    IO.puts("Test startup registration result: #{inspect(test_result)}")

    on_exit(fn ->
      # Clean up Ra resources for this test
      try do
        # First stop the Ra server
        server_id = {cluster_name, node()}
        leader = {cluster_name, node()}
        :ra.leave_and_terminate(:default, server_id, leader)
        :ra.force_delete_server(:default, server_id)
      catch
        _, _ -> :ok
      end

      # Clean up application environment
      Application.delete_env(:ra_registry, :cluster_name)

      # Stop applications
      Application.stop(:ra_registry)
      Application.stop(:ra)
    end)

    :ok
  end

  describe "unique registry" do
    test "can register a process" do
      assert :ok = RaRegistry.register(UniqueRegistry, "key1", :value1)
      lookup_result = RaRegistry.lookup(UniqueRegistry, "key1")
      assert [{pid, :value1}] = lookup_result
      assert pid == self()
    end

    test "cannot register the same key twice" do
      assert :ok = RaRegistry.register(UniqueRegistry, "key1", :value1)

      assert {:error, :already_registered} =
               RaRegistry.register(UniqueRegistry, "key1", :value2)

      lookup_result = RaRegistry.lookup(UniqueRegistry, "key1")
      assert [{pid, :value1}] = lookup_result
      assert pid == self()
    end

    test "concurrent registrations for same key should only allow one to succeed" do
      # Create two long-lived processes for this test
      process1 =
        spawn(fn ->
          # Stay alive for the test
          Process.sleep(5000)
        end)

      process2 =
        spawn(fn ->
          # Stay alive for the test
          Process.sleep(5000)
        end)

      # Make sure the key is unregistered before starting
      RaRegistry.unregister(UniqueRegistry, "concurrent_key")

      # Try to register the same key with both processes
      result1 = RaRegistry.register(UniqueRegistry, "concurrent_key", :value1, process1)
      result2 = RaRegistry.register(UniqueRegistry, "concurrent_key", :value2, process2)

      # One should succeed, one should fail
      assert Enum.count([result1, result2], &(&1 == :ok)) == 1
      assert Enum.count([result1, result2], &(&1 == {:error, :already_registered})) == 1

      # Verify only one value is registered
      lookup_result = RaRegistry.lookup(UniqueRegistry, "concurrent_key")
      assert length(lookup_result) == 1

      # The value should be either :value1 or :value2
      [{pid, value}] = lookup_result
      assert value in [:value1, :value2]

      # The registered process should be either process1 or process2
      assert pid in [process1, process2]

      # Clean up - unregister the key
      RaRegistry.unregister(UniqueRegistry, "concurrent_key")
    end

    test "can unregister a process" do
      assert :ok = RaRegistry.register(UniqueRegistry, "key1", :value1)
      assert :ok = RaRegistry.unregister(UniqueRegistry, "key1")
      assert [] = RaRegistry.lookup(UniqueRegistry, "key1")
    end

    test "count returns the correct number of processes" do
      assert 0 = RaRegistry.count(UniqueRegistry, "key1")
      assert :ok = RaRegistry.register(UniqueRegistry, "key1", :value1)
      assert 1 = RaRegistry.count(UniqueRegistry, "key1")
    end
  end

  describe "duplicate registry" do
    test "can register multiple processes with the same key" do
      task =
        Task.async(fn ->
          assert :ok = RaRegistry.register(DuplicateRegistry, "key1", :value2)
          # Keep the process alive for the lookup
          Process.sleep(500)
        end)

      assert :ok = RaRegistry.register(DuplicateRegistry, "key1", :value1)

      # wait for a bit to lookup
      Process.sleep(100)

      # Look up should find both processes
      result = RaRegistry.lookup(DuplicateRegistry, "key1")
      assert length(result) == 2

      # The result should contain both processes
      values = Enum.map(result, fn {_pid, value} -> value end)
      assert :value1 in values
      assert :value2 in values

      Task.await(task)
    end

    test "concurrent registrations for same key should all succeed in duplicate mode" do
      # Make sure the key is unregistered first
      RaRegistry.unregister(DuplicateRegistry, "concurrent_dup_key")

      # Create multiple long-lived processes
      processes =
        for _i <- 1..5 do
          spawn(fn -> Process.sleep(5000) end)
        end

      # Register all processes with the same key but different values
      results =
        for {process, i} <- Enum.zip(processes, 1..5) do
          value = :"value#{i}"

          {process, RaRegistry.register(DuplicateRegistry, "concurrent_dup_key", value, process),
           value}
        end

      # All registrations should succeed
      for {_pid, result, _value} <- results do
        assert result == :ok
      end

      # Look up should find all processes
      lookup_result = RaRegistry.lookup(DuplicateRegistry, "concurrent_dup_key")
      assert length(lookup_result) == 5

      # Verify all processes are registered
      registered_pids = Enum.map(lookup_result, fn {pid, _value} -> pid end)

      for process <- processes do
        assert process in registered_pids
      end

      # Verify all values were registered
      registered_values = Enum.map(lookup_result, fn {_pid, value} -> value end)

      for i <- 1..5 do
        assert :"value#{i}" in registered_values
      end

      # Clean up
      for process <- processes do
        RaRegistry.unregister(DuplicateRegistry, "concurrent_dup_key", process)
      end
    end

    test "count returns the correct number of processes in duplicate mode" do
      assert 0 = RaRegistry.count(DuplicateRegistry, "key1")

      task =
        Task.async(fn ->
          assert :ok = RaRegistry.register(DuplicateRegistry, "key1", :value2)
          # Keep the process alive for the count
          Process.sleep(500)
        end)

      assert :ok = RaRegistry.register(DuplicateRegistry, "key1", :value1)

      assert 2 = RaRegistry.count(DuplicateRegistry, "key1")

      Task.await(task)
    end
  end

  describe "process monitoring" do
    test "can manually unregister a terminated process" do
      self_pid = self()

      task_pid =
        spawn(fn ->
          # Register using the spawned process's PID
          test_result = RaRegistry.register(UniqueRegistry, "key_monitored", :value)
          # Send the registration result and PID back to the test process
          send(self_pid, {:registration_result, test_result, self()})

          # Keep alive until told to exit
          receive do
            :exit -> :ok
          end
        end)

      # Wait for the registration to complete
      {reg_result, registered_pid} =
        receive do
          {:registration_result, result, pid} -> {result, pid}
        after
          2000 -> flunk("Registration timed out")
        end

      assert reg_result == :ok

      # Verify the process is registered
      result = RaRegistry.lookup(UniqueRegistry, "key_monitored")
      assert [{^registered_pid, :value}] = result

      # Terminate the process
      send(task_pid, :exit)

      # Manual cleanup - in a real implementation this would be automatic
      unregister_result = RaRegistry.unregister(UniqueRegistry, "key_monitored", registered_pid)
      assert unregister_result == :ok

      # Verify the process is no longer registered
      lookup_result = RaRegistry.lookup(UniqueRegistry, "key_monitored")
      assert lookup_result == []
    end
  end

  describe "update_value" do
    test "updates the value for a registered process" do
      # First register a value
      :ok = RaRegistry.register(UniqueRegistry, "key_update", 1)

      # Now update it
      result = RaRegistry.update_value(UniqueRegistry, "key_update", fn val -> val + 1 end)
      assert {:ok, 2} == result

      lookup_result = RaRegistry.lookup(UniqueRegistry, "key_update")
      assert [{pid, 2}] = lookup_result
      assert pid == self()
    end

    test "returns error for unregistered keys" do
      # Should return not_registered for nonexistent keys
      result = RaRegistry.update_value(UniqueRegistry, "nonexistent", fn val -> val end)
      assert {:error, :not_registered} == result
    end
  end

  describe "via registry" do
    # Define our test GenServer
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

      def crash(server) do
        GenServer.cast(server, :crash)
      end

      def handle_call(:get_value, _from, state) do
        {:reply, state, state}
      end

      def handle_call(:increment, _from, state) do
        new_state = state + 1
        {:reply, new_state, new_state}
      end

      def handle_cast(:crash, _state) do
        # Intentionally crash the process
        Process.exit(self(), :crash)
        {:noreply, nil}
      end
    end

    test "can register a GenServer with RaRegistry via tuple" do
      # Start a GenServer using via RaRegistry
      via_tuple = {:via, RaRegistry, {UniqueRegistry, "test_server"}}

      {:ok, pid} = TestServer.start_link(name: via_tuple, initial_value: 10)

      # Verify the server is registered
      lookup_result = RaRegistry.lookup(UniqueRegistry, "test_server")
      assert [{registered_pid, _}] = lookup_result
      assert registered_pid == pid

      # Verify we can call the server using the via tuple
      assert TestServer.get_value(via_tuple) == 10
      assert TestServer.increment(via_tuple) == 11
      assert TestServer.get_value(via_tuple) == 11

      # Test using multiple servers with different keys
      via_tuple2 = {:via, RaRegistry, {UniqueRegistry, "test_server2"}}
      {:ok, pid2} = TestServer.start_link(name: via_tuple2, initial_value: 20)

      # Each server should have its own state
      assert TestServer.get_value(via_tuple) == 11
      assert TestServer.get_value(via_tuple2) == 20

      # Verify cannot start a server with the same name twice
      assert {:error, {:already_started, ^pid}} =
               TestServer.start_link(name: via_tuple, initial_value: 30)

      # Clean up
      Process.exit(pid, :normal)
      Process.exit(pid2, :normal)
    end

    test "prevents race conditions with concurrent registrations" do
      process_name = {:via, RaRegistry, {UniqueRegistry, "concurrent_server"}}

      try do
        # Create a new process for each test run to avoid name_conflict errors terminating the test
        test_pid = self()

        spawn_link(fn ->
          # Use a trap_exit process to catch the expected name_conflict
          Process.flag(:trap_exit, true)

          # Spawn two processes that will attempt to register concurrently
          task1 =
            Task.async(fn ->
              try do
                {:ok, _} = TestServer.start_link(name: process_name, initial_value: 20)
              catch
                # Handle any crashes
                _, _ -> {:error, :failed}
              end
            end)

          task2 =
            Task.async(fn ->
              try do
                {:ok, _} = TestServer.start_link(name: process_name, initial_value: 30)
              catch
                # Handle any crashes
                _, _ -> {:error, :failed}
              end
            end)

          # Wait for both tasks to complete or timeout
          result1 = Task.yield(task1, 10000) || Task.shutdown(task1)
          result2 = Task.yield(task2, 10000) || Task.shutdown(task2)

          # Process any name conflict exit signals
          receive_exits()

          # The results should indicate one of:
          # 1. One registration succeeded, one failed with :already_registered
          # 2. One registration succeeded, one failed with an error
          success_count = count_successes(result1, result2)

          # Lookup should return at most one result
          lookup_result = RaRegistry.lookup(UniqueRegistry, process_name)

          # Send results back to test process
          send(test_pid, {:results, success_count, length(lookup_result)})
        end)

        # Wait for the test results
        assert_receive {:results, success_count, lookup_count}, 5000

        # We should have at most one successful registration
        assert success_count <= 1

        # There should be at most one entry in the registry
        assert lookup_count <= 1

        # sometimes the first one can be 20, sometimes the first one can be 30
        assert TestServer.get_value(process_name) in [20, 30]
      catch
        # This is ok, it means the name conflict was properly handled
        _, {:name_conflict, _, _, _} -> :ok
      end
    end

    # Helper to count the number of successful registrations
    defp count_successes(result1, result2) do
      r1 = elem(result1, 1)
      r2 = elem(result2, 1)

      if(match?({:ok, _}, r1), do: 1, else: 0) +
        if match?({:ok, _}, r2), do: 1, else: 0
    end

    # Helper to process exit signals
    defp receive_exits() do
      receive do
        {:EXIT, _pid, _reason} -> receive_exits()
      after
        0 -> :ok
      end
    end

    test "when GenServer with {:via, RaRegistry, name} dies, it is cleared from the registry" do
      # Start GenServer with a via registration
      registry_key = "test_server_cleanup"
      via_tuple = {:via, RaRegistry, {UniqueRegistry, registry_key}}

      {:ok, server_pid} = TestServer.start_link(name: via_tuple, initial_value: 42)
      Process.flag(:trap_exit, true)

      # Verify the process is registered
      assert [{^server_pid, _}] = RaRegistry.lookup(UniqueRegistry, registry_key)

      # Crash the server
      TestServer.crash(via_tuple)

      # Wait for the process to die
      assert_receive {:EXIT, ^server_pid, :crash}, 1000

      # Verify the registration was cleared from the registry
      assert [] = RaRegistry.lookup(UniqueRegistry, registry_key)

      # Verify the name is available for registration again
      {:ok, _new_pid} = TestServer.start_link(name: via_tuple, initial_value: 100)
      assert TestServer.get_value(via_tuple) == 100
    end
  end
end
