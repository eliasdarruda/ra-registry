defmodule RaRegistry.Benchmarks do
  @moduledoc """
  Benchmarks for RaRegistry operations.

  To run these benchmarks, execute:

  ```
  mix run benchmarks/registry_bench.exs
  ```
  """

  # This module is used to generate predictable keys and values
  defmodule TestData do
    @max_keys 10_000

    def unique_key(n) when is_integer(n) and n > 0, do: "unique_key_#{n}"
    def duplicate_key(n) when is_integer(n) and n > 0, do: "duplicate_key_#{rem(n, 100)}"
    def value(n) when is_integer(n) and n > 0, do: "value_#{n}"
  end

  # This module simulates a consumer of the registry
  defmodule TestServer do
    use GenServer

    def start_link(opts) do
      id = Keyword.fetch!(opts, :id)
      registry = Keyword.fetch!(opts, :registry)
      initial_value = Keyword.get(opts, :initial_value, 0)

      GenServer.start_link(__MODULE__, initial_value, name: {:via, RaRegistry, {registry, id}})
    end

    def init(initial_value), do: {:ok, initial_value}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    def handle_call(:get, _from, state), do: {:reply, state, state}
    def handle_call({:set, value}, _from, _state), do: {:reply, :ok, value}
  end

  # This module provides the benchmark functions
  defmodule Scenarios do
    alias RaRegistry.Benchmarks.{TestData, TestServer}

    # Setup function to initialize the registries before benchmarks
    def setup do
      # Stop any existing Ra applications
      Application.stop(:ra_registry)
      Application.stop(:ra)

      # Start Ra and setup the registries
      Application.ensure_all_started(:ra)
      :ra_system.start_default()

      # Create unique test registry identifier
      test_id = :crypto.strong_rand_bytes(5) |> Base.encode16()
      unique_registry = String.to_atom("BenchUnique_#{test_id}")
      duplicate_registry = String.to_atom("BenchDuplicate_#{test_id}")

      # Start the registries
      RaRegistry.start_link(keys: :unique, name: unique_registry)
      RaRegistry.start_link(keys: :duplicate, name: duplicate_registry)

      %{
        unique_registry: unique_registry,
        duplicate_registry: duplicate_registry
      }
    end

    # Benchmark register with unique keys
    def register_unique(%{unique_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.register(registry, TestData.unique_key(i), TestData.value(i))
      end
    end

    # Benchmark lookup with unique keys
    def lookup_unique(%{unique_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.lookup(registry, TestData.unique_key(i))
      end
    end

    # Benchmark unregister with unique keys
    def unregister_unique(%{unique_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.unregister(registry, TestData.unique_key(i))
      end
    end

    # Benchmark register with duplicate keys
    def register_duplicate(%{duplicate_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.register(registry, TestData.duplicate_key(i), TestData.value(i))
      end
    end

    # Benchmark lookup with duplicate keys
    def lookup_duplicate(%{duplicate_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.lookup(registry, TestData.duplicate_key(i))
      end
    end

    # Benchmark count operations
    def count_operations(%{unique_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.count(registry, TestData.unique_key(i))
      end
    end

    # Benchmark via registrations
    def via_registration(%{unique_registry: registry}, count) do
      pids =
        for i <- 1..count do
          {:ok, pid} =
            case TestServer.start_link(
                   id: TestData.unique_key(i),
                   registry: registry,
                   initial_value: i
                 ) do
              {:ok, pid} -> pid
              {:error, {:already_started, pid}} -> pid
            end
        end

      # Return pids to be cleaned up later
      pids
    end

    # Benchmark via lookups
    def via_lookups(%{unique_registry: registry}, count) do
      for i <- 1..count do
        name = {:via, RaRegistry, {registry, TestData.unique_key(i)}}

        try do
          GenServer.call(name, :get)
        catch
          :exit, _ -> nil
        end
      end
    end

    # Cleanup function for unique registry benchmarks
    def cleanup_unique(%{unique_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.unregister(registry, TestData.unique_key(i))
      end
    end

    # Cleanup function for duplicate registry benchmarks
    def cleanup_duplicate(%{duplicate_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.unregister(registry, TestData.duplicate_key(i))
      end
    end

    # Cleanup function for via registration benchmarks
    def cleanup_via(pids) do
      for pid <- pids do
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end
    end
  end
end

# Setup context for benchmarks
context = RaRegistry.Benchmarks.Scenarios.setup()
counts = [10, 100, 1000]

# Define the benchmark inputs
inputs =
  for count <- counts, into: %{} do
    {count, count}
  end

# Run the benchmarks
Benchee.run(
  %{
    "register_unique" => fn count ->
      RaRegistry.Benchmarks.Scenarios.register_unique(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_unique(context, count)
    end,
    "lookup_unique" => fn count ->
      # Setup
      RaRegistry.Benchmarks.Scenarios.register_unique(context, count)
      # Benchmark
      result = RaRegistry.Benchmarks.Scenarios.lookup_unique(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_unique(context, count)
      result
    end,
    "unregister_unique" => fn count ->
      # Setup
      RaRegistry.Benchmarks.Scenarios.register_unique(context, count)
      # Benchmark
      result = RaRegistry.Benchmarks.Scenarios.unregister_unique(context, count)
      result
    end,
    "register_duplicate" => fn count ->
      RaRegistry.Benchmarks.Scenarios.register_duplicate(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_duplicate(context, count)
    end,
    "lookup_duplicate" => fn count ->
      # Setup
      RaRegistry.Benchmarks.Scenarios.register_duplicate(context, count)
      # Benchmark
      result = RaRegistry.Benchmarks.Scenarios.lookup_duplicate(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_duplicate(context, count)
      result
    end,
    "count_operations" => fn count ->
      # Setup
      RaRegistry.Benchmarks.Scenarios.register_unique(context, count)
      # Benchmark
      result = RaRegistry.Benchmarks.Scenarios.count_operations(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_unique(context, count)
      result
    end,
    "via_registration" => fn count ->
      pids = RaRegistry.Benchmarks.Scenarios.via_registration(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_via(pids)
      pids
    end,
    "via_lookups" => fn count ->
      # Setup
      pids = RaRegistry.Benchmarks.Scenarios.via_registration(context, count)
      # Benchmark
      result = RaRegistry.Benchmarks.Scenarios.via_lookups(context, count)
      # Cleanup
      RaRegistry.Benchmarks.Scenarios.cleanup_via(pids)
      result
    end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [fast_warning: false]
)

# Create another benchmark for update_value operations
update_context = RaRegistry.Benchmarks.Scenarios.setup()
update_counts = [10, 100, 500]

update_inputs =
  for count <- update_counts, into: %{} do
    {count, count}
  end

Benchee.run(
  %{
    "update_value" => fn count ->
      # Setup
      registry = update_context.unique_registry

      for i <- 1..count do
        RaRegistry.register(registry, RaRegistry.Benchmarks.TestData.unique_key(i), i)
      end

      # Benchmark
      for i <- 1..count do
        RaRegistry.update_value(
          registry,
          RaRegistry.Benchmarks.TestData.unique_key(i),
          fn value -> value + 1 end
        )
      end

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.Benchmarks.TestData.unique_key(i))
      end
    end
  },
  inputs: update_inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [fast_warning: false]
)

# Create a concurrent operations benchmark
concurrency_context = RaRegistry.Benchmarks.Scenarios.setup()
concurrency_counts = [10, 50, 100]

concurrency_inputs =
  for count <- concurrency_counts, into: %{} do
    {count, count}
  end

Benchee.run(
  %{
    "concurrent_unique_registrations" => fn count ->
      registry = concurrency_context.unique_registry
      # Use tasks to simulate concurrent operations
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            RaRegistry.register(registry, RaRegistry.Benchmarks.TestData.unique_key(i), i)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.Benchmarks.TestData.unique_key(i))
      end

      results
    end,
    "concurrent_duplicate_registrations" => fn count ->
      registry = concurrency_context.duplicate_registry
      # Use tasks to simulate concurrent operations
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            RaRegistry.register(registry, RaRegistry.Benchmarks.TestData.duplicate_key(i), i)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.Benchmarks.TestData.duplicate_key(i))
      end

      results
    end,
    "concurrent_lookups" => fn count ->
      registry = concurrency_context.unique_registry

      # Setup - register entries
      for i <- 1..count do
        RaRegistry.register(registry, RaRegistry.Benchmarks.TestData.unique_key(i), i)
      end

      # Use tasks to simulate concurrent lookups
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            RaRegistry.lookup(registry, RaRegistry.Benchmarks.TestData.unique_key(i))
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.Benchmarks.TestData.unique_key(i))
      end

      results
    end
  },
  inputs: concurrency_inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [fast_warning: false]
)
