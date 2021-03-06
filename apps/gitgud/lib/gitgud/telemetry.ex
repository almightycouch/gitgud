defmodule GitGud.Telemetry do
  @moduledoc false

  require Logger

  def handle_event([:gitrekt, :git_agent, :execute], %{duration: duration}, %{op: op, args: args} = meta, _config) do
    args = Enum.join(map_git_agent_op_args(op, args), ", ")
    if Map.get(meta, :cache),
      do: Logger.debug("[Git Agent] #{op}(#{args}) executed in ⚡ #{duration_inspect(duration)}"),
    else: Logger.debug("[Git Agent] #{op}(#{args}) executed in #{duration_inspect(duration)}")
  end

  def handle_event([:gitrekt, :git_agent, :stream], %{duration: duration}, %{op: op, args: args, chunk_size: chunk_size}, _config) do
    args = Enum.join(map_git_agent_op_args(op, args), ", ")
    Logger.debug("[Git Agent] #{op}(#{args}) streamed #{chunk_size} items in #{duration_inspect(duration)}")
  end

  def handle_event([:gitrekt, :wire_protocol, command], %{duration: duration}, %{service: service}, _config) do
    Logger.debug("[Wire Protocol] #{command} executed #{service.state} in #{duration_inspect(duration)}")
  end

  def handle_event([:absinthe, :execute, :operation, :stop], %{duration: duration}, meta, _config) do
    [%{name: name, type: type, args: args}|_] = Enum.map(meta.blueprint.operations, &map_absinthe_op/1)
    args = Enum.join(map_absinthe_op_args(args), ", ")
    Logger.debug("[GraphQL] #{type} #{name}(#{args}) executed in #{duration_inspect(duration / 1_000)}")
  end

  #
  # Helpers
  #

  defp duration_inspect(duration) do
    cond do
      duration > 1_000_000 ->
        "#{Float.round(duration / 1_000_000, 2)} s"
      duration > 1_000 ->
        "#{Float.round(duration / 1_000, 2)} ms"
      true ->
        "#{duration} µs"
    end
  end

  defp inspect_oid(oid) do
    oid
    |> Base.encode16(case: :lower)
    |> String.slice(0, 7)
    |> inspect()
  end

  defp map_git_agent_op_args(:odb_read, [odb, oid]), do: [inspect(odb), inspect_oid(oid)]
  defp map_git_agent_op_args(:odb_write, [odb, data, type]), do: [inspect(odb), "<<... #{byte_size(data)} bytes>>", inspect(type)]
  defp map_git_agent_op_args(:odb_object_exists?, [odb, oid]), do: [inspect(odb), inspect_oid(oid)]
  defp map_git_agent_op_args(:references, [:undefined, opts]), do: Enum.map(opts, &inspect/1)
  defp map_git_agent_op_args(:references_with, [:undefined, opts]), do: Enum.map(opts, &inspect/1)
  defp map_git_agent_op_args(:reference_create, [name, :oid, oid, force]), do: [inspect(name), inspect(:oid), inspect_oid(oid), inspect(force)]
  defp map_git_agent_op_args(:object, [oid]), do: [inspect_oid(oid)]
  defp map_git_agent_op_args(:graph_ahead_behind, [oid, oid]), do: [inspect_oid(oid), inspect_oid(oid)]
  defp map_git_agent_op_args(:commit_create, [update_ref, author, committer, message, tree_oid, parents_oids]), do: [inspect(update_ref), inspect(author), inspect(committer), inspect(message), inspect_oid(tree_oid), inspect(Enum.map(parents_oids, &inspect_oid/1))]
  defp map_git_agent_op_args(:tree_entry, [revision, {:oid, oid}]), do: [inspect(revision), inspect({:oid, inspect_oid(oid)})]
  defp map_git_agent_op_args(:index_add, [index, oid, path, file_size, mode, opts]), do: [inspect(index), inspect_oid(oid), inspect(path), inspect(file_size), inspect(mode), inspect(opts)]
  defp map_git_agent_op_args(:pack_create, [oids]), do: [inspect(Enum.map(oids, &inspect_oid/1))]
  defp map_git_agent_op_args(:transaction, [{:commit_info, oid}, _callback]), do: [:commit_info, inspect_oid(oid)]
  defp map_git_agent_op_args(:transaction, [nil, callback]), do: [inspect(callback)]
  defp map_git_agent_op_args(_op, args), do: Enum.map(args, &inspect/1)

  defp map_absinthe_op(%Absinthe.Blueprint.Document.Operation{name: name, type: type, variable_definitions: var_defs, variable_uses: var_uses}) when is_binary(name) do
    %{name: name, type: type, args: Enum.map(var_uses, fn %{name: name} -> {name, Enum.find_value(var_defs, &(&1.name == name && map_absinthe_input_value(&1.provided_value)))} end)}
  end

  defp map_absinthe_op(%Absinthe.Blueprint.Document.Operation{type: type, selections: [selection|_]}) do
    %{name: selection.name, type: type, args: Enum.map(selection.argument_data, fn {key, val} -> {Absinthe.Utils.camelize(to_string(key), lower: true), val} end)}
  end

  defp map_absinthe_op_args(args) do
    Enum.map(args, fn {name, val} -> "#{name}: #{inspect(val)}" end)
  end

  defp map_absinthe_input_value(%Absinthe.Blueprint.Input.RawValue{content: input_value}), do: map_absinthe_input_value(input_value)
  defp map_absinthe_input_value(%Absinthe.Blueprint.Input.List{items: []}), do: []
  defp map_absinthe_input_value(%Absinthe.Blueprint.Input.List{items: items}), do: Enum.map(items, &map_absinthe_input_value/1)
  defp map_absinthe_input_value(%{value: value}), do: value

# defp map_absinthe_field(i) when is_integer(i), do: [to_string(i)]
# defp map_absinthe_field(%Absinthe.Blueprint.Document.Field{name: name}), do: [name]
# defp map_absinthe_field(%Absinthe.Blueprint.Document.Operation{}), do: []
# def map_absinthe_field(%Absinthe.Blueprint.Document.Operation{} = op) do
#   %{name: name, args: args} = map_absinthe_op(op)
#   args = Enum.join(map_absinthe_op_args(args), ", ")
#   ["#{name}(#{args})"]
# end

end
