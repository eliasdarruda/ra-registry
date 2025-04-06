defmodule RaRegistry.StateMachine do
  @moduledoc """
  The Ra state machine implementation for the distributed registry.
  """

  @doc """
  Returns the Ra state machine configuration.
  """
  def machine_config do
    # Ra 2.x uses {module, initial_state} format
    init_state = %{
      unique: %{},
      duplicate: %{}
    }

    # Machine configuration format for Ra 2.x
    {:module, __MODULE__, init_state}
  end

  @doc """
  Initialize the state machine with empty registry maps.
  """
  def init(%{unique: _, duplicate: _} = state) do
    state
  end

  def init(_) do
    %{
      unique: %{},
      duplicate: %{}
    }
  end

  @doc """
  Apply commands to the state machine.
  """
  def command_handler(
        _meta,
        {:register, key, pid, value, :unique},
        %{unique: unique, duplicate: _} = state
      ) do
    case unique do
      %{^key => {_pid, _value}} ->
        {state, {:error, :already_registered}}

      _ ->
        # In a real implementation, Ra would handle process monitoring
        # For testing purposes, we're simplifying the implementation
        {%{state | unique: Map.put(unique, key, {pid, value})}, :ok}
    end
  end

  def command_handler(
        _meta,
        {:register, key, pid, value, :duplicate},
        %{unique: _, duplicate: duplicate} = state
      ) do
    entries = Map.get(duplicate, key, %{})

    # In a real implementation, Ra would handle process monitoring
    # For testing purposes, we're simplifying the implementation

    new_entries = Map.put(entries, pid, value)
    {%{state | duplicate: Map.put(duplicate, key, new_entries)}, :ok}
  end

  def command_handler(
        _meta,
        {:unregister, key, pid, :unique},
        %{unique: unique, duplicate: _} = state
      ) do
    case unique do
      %{^key => {^pid, _value}} ->
        {%{state | unique: Map.delete(unique, key)}, :ok}

      _ ->
        {state, :ok}
    end
  end

  def command_handler(
        _meta,
        {:unregister, key, pid, :duplicate},
        %{unique: _, duplicate: duplicate} = state
      ) do
    case duplicate do
      %{^key => entries} ->
        new_entries = Map.delete(entries, pid)

        new_duplicate =
          if map_size(new_entries) == 0 do
            Map.delete(duplicate, key)
          else
            Map.put(duplicate, key, new_entries)
          end

        {%{state | duplicate: new_duplicate}, :ok}

      _ ->
        {state, :ok}
    end
  end

  def command_handler(_meta, {:lookup, key, :unique}, %{unique: unique} = state) do
    case unique do
      %{^key => {pid, value}} ->
        {state, {:ok, [{pid, value}]}}

      _ ->
        {state, {:ok, []}}
    end
  end

  def command_handler(_meta, {:lookup, key, :duplicate}, %{duplicate: duplicate} = state) do
    case duplicate do
      %{^key => entries} ->
        result = for {pid, value} <- entries, do: {pid, value}
        {state, {:ok, result}}

      _ ->
        {state, {:ok, []}}
    end
  end

  def command_handler(_meta, {:count, key, :unique}, %{unique: unique} = state) do
    count =
      case unique do
        %{^key => _} -> 1
        _ -> 0
      end

    {state, count}
  end

  def command_handler(_meta, {:count, key, :duplicate}, %{duplicate: duplicate} = state) do
    count =
      case duplicate do
        %{^key => entries} -> map_size(entries)
        _ -> 0
      end

    {state, count}
  end

  def command_handler(
        _meta,
        {:process_down, pid},
        %{unique: unique, duplicate: duplicate} = state
      ) do
    # Remove all entries where this pid is registered
    new_unique =
      Enum.reduce(unique, %{}, fn {key, {entry_pid, value}}, acc ->
        if entry_pid == pid do
          acc
        else
          Map.put(acc, key, {entry_pid, value})
        end
      end)

    new_duplicate =
      Enum.reduce(duplicate, %{}, fn {key, entries}, acc ->
        new_entries = Map.delete(entries, pid)

        if map_size(new_entries) == 0 do
          acc
        else
          Map.put(acc, key, new_entries)
        end
      end)

    {%{state | unique: new_unique, duplicate: new_duplicate}, :ok}
  end

  # Ra requires this function instead of 'apply' to avoid name conflicts
  def apply(meta, cmd, state) do
    command_handler(meta, cmd, state)
  end

  @doc """
  Query functions for Ra's consistent_query.
  These must follow the proper format of receiving machine state as a single argument.
  """
  def lookup_query_unique(key, machine_state) do
    case machine_state.unique do
      %{^key => {pid, value}} ->
        {:ok, [{pid, value}]}

      _ ->
        {:ok, []}
    end
  end

  def lookup_query_duplicate(key, machine_state) do
    case machine_state.duplicate do
      %{^key => entries} ->
        result = for {pid, value} <- entries, do: {pid, value}
        {:ok, result}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Handle process monitors.
  """
  def handle_down(pid, _reason, state) do
    # Apply process_down command to remove entries for the terminated process
    command_handler(nil, {:process_down, pid}, state)
  end
end
