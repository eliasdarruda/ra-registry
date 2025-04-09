defmodule RaRegistry.ComparisonBenchmarks do
  @moduledoc """
  Benchmarks comparing RaRegistry with Elixir's built-in Registry.

  To run these benchmarks, execute:

  ```
  mix run benchmarks/comparison_bench.exs
  ```
  """

  defmodule TestData do
    @max_keys 10_000

    def unique_key(n) when is_integer(n) and n > 0, do: "key_#{n}"
    def value(n) when is_integer(n) and n > 0, do: "value_#{n}"
  end

  defmodule Scenarios do
    alias RaRegistry.ComparisonBenchmarks.TestData

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
      ra_registry = String.to_atom("RaRegistry_#{test_id}")
      elixir_registry = String.to_atom("ElixirRegistry_#{test_id}")

      # Start the registries
      RaRegistry.start_link(keys: :unique, name: ra_registry)
      Registry.start_link(keys: :unique, name: elixir_registry)

      %{
        ra_registry: ra_registry,
        elixir_registry: elixir_registry
      }
    end

    # Benchmarks for RaRegistry operations
    def ra_register(%{ra_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.register(registry, TestData.unique_key(i), TestData.value(i))
      end
    end

    def ra_lookup(%{ra_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.lookup(registry, TestData.unique_key(i))
      end
    end

    def ra_unregister(%{ra_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.unregister(registry, TestData.unique_key(i))
      end
    end

    # Benchmarks for built-in Registry operations
    def elixir_register(%{elixir_registry: registry}, count) do
      for i <- 1..count do
        Registry.register(registry, TestData.unique_key(i), TestData.value(i))
      end
    end

    def elixir_lookup(%{elixir_registry: registry}, count) do
      for i <- 1..count do
        Registry.lookup(registry, TestData.unique_key(i))
      end
    end

    def elixir_unregister(%{elixir_registry: registry}, count) do
      for i <- 1..count do
        Registry.unregister(registry, TestData.unique_key(i))
      end
    end

    # Cleanup functions
    def cleanup_ra(%{ra_registry: registry}, count) do
      for i <- 1..count do
        RaRegistry.unregister(registry, TestData.unique_key(i))
      end
    end

    def cleanup_elixir(%{elixir_registry: registry}, count) do
      for i <- 1..count do
        Registry.unregister(registry, TestData.unique_key(i))
      end
    end
  end
end

# Setup context for benchmarks
context = RaRegistry.ComparisonBenchmarks.Scenarios.setup()
counts = [10, 100, 1000]

# Define the benchmark inputs
inputs =
  for count <- counts, into: %{} do
    {count, count}
  end

# Run the benchmarks
Benchee.run(
  %{
    "ra_registry_register" => fn count ->
      RaRegistry.ComparisonBenchmarks.Scenarios.ra_register(context, count)
      # Cleanup
      RaRegistry.ComparisonBenchmarks.Scenarios.cleanup_ra(context, count)
    end,
    "elixir_registry_register" => fn count ->
      RaRegistry.ComparisonBenchmarks.Scenarios.elixir_register(context, count)
      # Cleanup
      RaRegistry.ComparisonBenchmarks.Scenarios.cleanup_elixir(context, count)
    end,
    "ra_registry_lookup" => fn count ->
      # Setup
      RaRegistry.ComparisonBenchmarks.Scenarios.ra_register(context, count)
      # Benchmark
      result = RaRegistry.ComparisonBenchmarks.Scenarios.ra_lookup(context, count)
      # Cleanup
      RaRegistry.ComparisonBenchmarks.Scenarios.cleanup_ra(context, count)
      result
    end,
    "elixir_registry_lookup" => fn count ->
      # Setup
      RaRegistry.ComparisonBenchmarks.Scenarios.elixir_register(context, count)
      # Benchmark
      result = RaRegistry.ComparisonBenchmarks.Scenarios.elixir_lookup(context, count)
      # Cleanup
      RaRegistry.ComparisonBenchmarks.Scenarios.cleanup_elixir(context, count)
      result
    end,
    "ra_registry_unregister" => fn count ->
      # Setup
      RaRegistry.ComparisonBenchmarks.Scenarios.ra_register(context, count)
      # Benchmark
      RaRegistry.ComparisonBenchmarks.Scenarios.ra_unregister(context, count)
    end,
    "elixir_registry_unregister" => fn count ->
      # Setup
      RaRegistry.ComparisonBenchmarks.Scenarios.elixir_register(context, count)
      # Benchmark
      RaRegistry.ComparisonBenchmarks.Scenarios.elixir_unregister(context, count)
    end
  },
  inputs: inputs,
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [fast_warning: false]
)

# Create a concurrent operations comparison benchmark
concurrency_context = RaRegistry.ComparisonBenchmarks.Scenarios.setup()
concurrency_counts = [10, 50, 100]

concurrency_inputs =
  for count <- concurrency_counts, into: %{} do
    {count, count}
  end

Benchee.run(
  %{
    "ra_registry_concurrent_register" => fn count ->
      registry = concurrency_context.ra_registry
      # Use tasks to simulate concurrent operations
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            RaRegistry.register(
              registry,
              RaRegistry.ComparisonBenchmarks.TestData.unique_key(i),
              i
            )
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
      end

      results
    end,
    "elixir_registry_concurrent_register" => fn count ->
      registry = concurrency_context.elixir_registry
      # Use tasks to simulate concurrent operations
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            Registry.register(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i), i)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        Registry.unregister(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
      end

      results
    end,
    "ra_registry_concurrent_lookup" => fn count ->
      registry = concurrency_context.ra_registry

      # Setup - register entries
      for i <- 1..count do
        RaRegistry.register(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i), i)
      end

      # Use tasks to simulate concurrent lookups
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            RaRegistry.lookup(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        RaRegistry.unregister(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
      end

      results
    end,
    "elixir_registry_concurrent_lookup" => fn count ->
      registry = concurrency_context.elixir_registry

      # Setup - register entries
      for i <- 1..count do
        Registry.register(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i), i)
      end

      # Use tasks to simulate concurrent lookups
      tasks =
        for i <- 1..count do
          Task.async(fn ->
            Registry.lookup(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Cleanup
      for i <- 1..count do
        Registry.unregister(registry, RaRegistry.ComparisonBenchmarks.TestData.unique_key(i))
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
