# This script runs all benchmarks in sequence
IO.puts("Running RaRegistry benchmarks...")

# Run basic registry benchmark
IO.puts("\n=== BASIC REGISTRY BENCHMARK ===\n")
Code.eval_file("benchmarks/registry_bench.exs")

# Run comparison benchmark
IO.puts("\n=== COMPARISON BENCHMARK ===\n")
Code.eval_file("benchmarks/comparison_bench.exs")

IO.puts("\nAll benchmarks completed.")
