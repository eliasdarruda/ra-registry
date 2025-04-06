defmodule RaRegistry do
  @moduledoc """
  A distributed registry for Elixir GenServers using Ra (RabbitMQ's Raft implementation).

  RaRegistry provides similar functionality to Elixir's built-in Registry module,
  but with distributed consensus via Ra, making it suitable for distributed
  applications across multiple nodes.

  It supports both :unique and :duplicate registration modes.

  ## Usage

  First, set up the cluster in your application configuration:

  ```elixir
  config :ra_registry, cluster_name: :my_registry_cluster
  ```

  Then use the registry in your code:

  ```elixir
  # Register a process with a unique key
  RaRegistry.register(:my_registry, "unique_key", :some_value)

  # Look up a process by key
  RaRegistry.lookup(:my_registry, "unique_key")

  # Register with a duplicate key
  RaRegistry.register(:my_duplicate_registry, "shared_key", :value1)
  RaRegistry.register(:my_duplicate_registry, "shared_key", :value2)

  # Look up all processes with the duplicate key
  RaRegistry.lookup(:my_duplicate_registry, "shared_key")
  ```

  ## Via Registration

  You can also use RaRegistry as a process registry with GenServer and other OTP processes
  by using the `:via` tuple:

  ```elixir
  # Start a GenServer with RaRegistry
  name = {:via, RaRegistry, {MyRegistry, "my_server"}}
  {:ok, pid} = GenServer.start_link(MyServer, arg, name: name)

  # Call the server using the same via tuple
  GenServer.call(name, :some_request)
  ```
  """

  @doc """
  Starts a new registry with the given name and options.

  ## Options

  * `:keys` - The kind of keys in this registry. Can be either `:unique` or
    `:duplicate` (required).
  * `:name` - A local or global name for the registry (required).

  ## Examples

      RaRegistry.start_link(keys: :unique, name: MyRegistry)
      RaRegistry.start_link(keys: :duplicate, name: {MyRegistry, self()})
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    # Start a supervision tree with the manager
    children = [
      {RaRegistry.Manager, opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: supervisor_name(name))
  end

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options) when is_list(options) do
    id = Keyword.get(options, :name, RaRegistry)

    %{
      id: id,
      start: {RaRegistry, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc """
  Returns the registry key type, either :unique or :duplicate.
  """
  def keys(name) do
    GenServer.call(name, :get_keys)
  end

  @doc """
  Registers the given process under the given key in the registry.
  If no pid is provided, registers the current process.

  ## Examples

      RaRegistry.register(MyRegistry, "key", :value)
      RaRegistry.register(MyRegistry, "key", :value, other_pid)
  """
  def register(name, key, value \\ nil, pid \\ nil) do
    pid = pid || self()
    GenServer.call(name, {:register, key, pid, value})
  end

  @doc """
  Unregisters the current process for the given key in the registry.

  ## Examples

      RaRegistry.unregister(MyRegistry, "key")
  """
  def unregister(name, key, pid \\ nil) do
    pid = pid || self()
    GenServer.call(name, {:unregister, key, pid})
  end

  @doc """
  Looks up the given key in the registry and returns the associated processes.

  ## Examples

      RaRegistry.lookup(MyRegistry, "key")
  """
  def lookup(name, key) do
    GenServer.call(name, {:lookup, key})
  end

  @doc """
  Returns the number of processes registered under the given key.

  ## Examples

      RaRegistry.count(MyRegistry, "key")
  """
  def count(name, key) do
    GenServer.call(name, {:count, key})
  end

  @doc """
  Updates the value associated with the key for the current process.

  ## Examples

      RaRegistry.update_value(MyRegistry, "key", fn value -> value + 1 end)
  """
  def update_value(name, key, callback) when is_function(callback, 1) do
    GenServer.call(name, {:update_value, key, self(), callback})
  end

  @doc """
  Returns a stream of all processes in the registry.
  """
  def match(name, key, pattern) do
    GenServer.call(name, {:match, key, pattern})
  end

  # Private helpers

  defp supervisor_name(name) do
    :"#{name}.Supervisor"
  end

  @doc """
  Implementation for the `:via` registration mechanism.
  Registers the current process under the given `key` in the registry `name`.
  Returns `:yes` if registration succeeds, `:no` otherwise.
  """
  @spec register_name({registry :: term, key :: term}, pid) :: :yes | :no
  def register_name({registry, key}, pid) do
    # For compatibility with GenServer :via
    # We must use the provided pid, not self()
    case register(registry, key, nil, pid) do
      :ok -> :yes
      _ -> :no
    end
  end

  @doc """
  Implementation for the `:via` registration mechanism.
  Returns the pid associated with the given `key` in the registry `name`.
  Returns `pid` if successful, `:undefined` otherwise.
  """
  @spec whereis_name({registry :: term, key :: term}) :: pid | :undefined
  def whereis_name({registry, key}) do
    case lookup(registry, key) do
      [{pid, _}] -> pid
      _ -> :undefined
    end
  end

  @doc """
  Implementation for the `:via` registration mechanism.
  Unregisters the given `key` from the registry `name`.
  """
  @spec unregister_name({registry :: term, key :: term}) :: :ok
  def unregister_name({registry, key}) do
    unregister(registry, key)
    :ok
  end

  @doc """
  Implementation for the `:via` registration mechanism.
  Sends a message to the process registered under the given `key` in `registry`.
  """
  @spec send({registry :: term, key :: term}, message :: term) :: pid
  def send({registry, key}, message) do
    case whereis_name({registry, key}) do
      :undefined ->
        raise "No process registered with key #{inspect(key)} in registry #{inspect(registry)}"

      pid ->
        Kernel.send(pid, message)
        pid
    end
  end
end
