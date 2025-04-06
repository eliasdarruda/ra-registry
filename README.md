# RaRegistry

A distributed Registry for Elixir GenServers using [Ra](https://github.com/rabbitmq/ra) (RabbitMQ's Raft implementation).

## Overview

RaRegistry provides similar functionality to Elixir's built-in [Registry](https://hexdocs.pm/elixir/Registry.html) module, but with distributed consensus via Ra, making it suitable for distributed applications across multiple nodes.

Key features:
- Support for both `:unique` and `:duplicate` registration modes
- Automatic process monitoring and cleanup
- Built on Ra, RabbitMQ's implementation of the Raft consensus protocol
- Regular operations with strong consistency during normal cluster operation
- Familiar API similar to Elixir's built-in Registry
- Enhanced recovery mechanisms for handling SIGKILL scenarios
- Seamless integration with GenServer via the `:via` tuple registration

## Installation

Add `ra_registry` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ra_registry, "~> 0.1.0"}
  ]
end
```

## Configuration

Configure the Ra cluster in your application configuration:

```elixir
config :ra_registry, cluster_name: :my_registry_cluster
```

## Usage with GenServer (Recommended)

The most common and recommended way to use RaRegistry is with GenServer via the `:via` tuple registration. This ensures your GenServers can be discovered across all nodes in your cluster:

```elixir
defmodule MyApp do
  # Add RaRegistry to your application supervision tree
  def start(_type, _args) do
    children = [
      # Start RaRegistry before any services that depend on it
      {RaRegistry, keys: :unique, name: MyApp.Registry},
      
      # Other children in your supervision tree...
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule MyApp.Server do
  use GenServer
  
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    initial_state = Keyword.get(opts, :initial_state, %{})
    
    GenServer.start_link(__MODULE__, initial_state, name: via_tuple(id))
  end
  
  def call(id, message) do
    GenServer.call(via_tuple(id), message)
  end

  defp via_tuple(id), do: {:via, RaRegistry, {MyApp.Registry, id}}
  
  # GenServer implementation
  def init(state), do: {:ok, state}
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
  def handle_call({:set, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
end

# Then, in your application code:
{:ok, pid} = MyApp.Server.start_link(id: "user_123")

# This call will work from any node in the cluster
MyApp.Server.call("user_123", {:set, :name, "John"})
MyApp.Server.call("user_123", {:get, :name}) # => "John"
```

## Direct API Usage

RaRegistry can also be used directly for more complex scenarios:

```elixir
# Start registries (typically done in your application supervision tree)
RaRegistry.start_link(keys: :unique, name: MyRegistry)
RaRegistry.start_link(keys: :duplicate, name: DuplicateRegistry)

# Register processes
RaRegistry.register(MyRegistry, "unique_key", :some_value)
RaRegistry.register(DuplicateRegistry, "shared_key", :some_value)

# Look up processes
RaRegistry.lookup(MyRegistry, "unique_key")
# => [{#PID<0.123.0>, :some_value}]

RaRegistry.lookup(DuplicateRegistry, "shared_key")
# => [{#PID<0.123.0>, :some_value}, {#PID<0.124.0>, :other_value}]

# Count registered processes
RaRegistry.count(MyRegistry, "unique_key") # => 1
RaRegistry.count(DuplicateRegistry, "shared_key") # => 2

# Unregister processes
RaRegistry.unregister(MyRegistry, "unique_key")
```

## Integration in Supervision Tree

To properly integrate RaRegistry in your application, add it to your supervision tree:

```elixir
# In your application.ex file:
def start(_type, _args) do
  children = [
    # Start RaRegistry with your desired configuration
    {RaRegistry, keys: :unique, name: MyApp.Registry},
    
    # Other services that depend on RaRegistry
    MyApp.SomeService,
    {MyApp.WorkerSupervisor, registry: MyApp.Registry}
  ]

  # Use a supervision strategy that matches your needs
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Cluster Management

You can manage the RaRegistry cluster using these functions:

```elixir
# Get current cluster members
RaRegistry.Manager.get_members(MyApp.Registry)

# Add a node to the cluster
RaRegistry.Manager.add_member(MyApp.Registry, :"node2@host")

# Remove a node from the cluster
RaRegistry.Manager.remove_member(MyApp.Registry, :"node2@host")
```

## Consistency and Recovery

### Consistency Model

RaRegistry offers these consistency guarantees:

- **Normal Operation**: Operations use the Raft consensus protocol via Ra, providing strong consistency when a majority of nodes are available
- **State Machine Atomicity**: Operations within the Ra state machine are atomic and either fully succeed or have no effect
- **Best-Effort Recovery**: During failure scenarios like SIGKILL of the leader, our implementation employs aggressive recovery mechanisms that prioritize availability and eventual recovery

It's important to understand that:
- The custom recovery mechanisms we've implemented extend beyond the standard Raft protocol
- During severe failures, the implementation might briefly prioritize availability over strict consistency
- After recovery, the system returns to a consistent state, though some in-flight operations might be lost

### Recovery Capabilities

RaRegistry includes specialized recovery mechanisms to handle various failure scenarios:

- Automatic leader election after clean node failures
- Emergency recovery procedures for SIGKILL scenarios
- Self-healing mechanisms when nodes rejoin the cluster
- Cleanup of dead process registrations

For critical systems, we recommend running at least 3 nodes to ensure quorum is maintained even if one node fails. This allows the system to continue operating consistently during most types of failures.

## License

Apache License 2.0
