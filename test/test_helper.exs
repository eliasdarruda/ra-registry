# Exclude distributed tests by default (they require peer nodes)
# Run them explicitly with: mix test --include distributed
ExUnit.start(exclude: [:distributed])
