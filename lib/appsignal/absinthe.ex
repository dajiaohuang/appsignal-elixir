defmodule Appsignal.Absinthe do
  require Logger

  @tracer Application.compile_env(:appsignal, :appsignal_tracer, Appsignal.Tracer)
  @span Application.compile_env(:appsignal, :appsignal_span, Appsignal.Span)
  @operation_span_stack_key {__MODULE__, :operation_span_stack}

  @moduledoc """
  Absinthe telemetry integration.

  Absinthe does not emit an operation-stop event when a resolver raises. To
  record resolver exceptions and close the GraphQL span, delegate your schema's
  `middleware/3` callback to `middleware/3` here:

      def middleware(middleware, field, object) do
        Appsignal.Absinthe.middleware(middleware, field, object)
      end
  """

  def attach do
    handlers = %{
      [:absinthe, :execute, :operation, :start] => &__MODULE__.absinthe_execute_operation_start/4,
      [:absinthe, :execute, :operation, :stop] => &__MODULE__.absinthe_execute_operation_stop/4
    }

    for {event, fun} <- handlers do
      detach = :telemetry.detach({__MODULE__, event})
      attach = :telemetry.attach({__MODULE__, event}, event, fun, :ok)

      case {detach, attach} do
        {:ok, :ok} ->
          _ =
            Appsignal.IntegrationLogger.debug(
              "Appsignal.Absinthe reattached to #{inspect(event)}"
            )

          :ok

        {{:error, :not_found}, :ok} ->
          _ =
            Appsignal.IntegrationLogger.debug("Appsignal.Absinthe attached to #{inspect(event)}")

          :ok

        {_, {:error, _} = error} ->
          Logger.warning(
            "Appsignal.Absinthe not attached to #{inspect(event)}: #{inspect(error)}"
          )

          error
      end
    end
  end

  def absinthe_execute_operation_start(_event, _measurements, metadata, _config) do
    operation_name = metadata[:options][:operation_name]

    span =
      "graphql"
      |> @tracer.create_span(@tracer.current_span())
      |> @span.set_name(operation_name || "graphql")
      |> @span.set_attribute("appsignal:category", "call.graphql")

    push_operation_span(span)

    root_span = @tracer.root_span()

    root_span
    |> @span.set_namespace_if_nil("graphql")

    if operation_name do
      root_span
      |> @span.set_name_if_nil(operation_name)
    end
  end

  def absinthe_execute_operation_stop(_event, _measurements, _metadata, _config) do
    @tracer.close_span(pop_operation_span() || @tracer.current_span())
  end

  @doc "Wraps Absinthe's resolver middleware to record exceptions and close the GraphQL span."
  def middleware(middleware, _field, _object) do
    Enum.map(middleware, fn
      {Absinthe.Resolution, resolver} -> {Absinthe.Resolution, wrap_resolver(resolver)}
      middleware -> middleware
    end)
  end

  @doc false
  def wrap_resolver(resolver) when is_function(resolver, 2) do
    fn _source, arguments, resolution ->
      with_error_tracking(fn -> resolver.(arguments, resolution) end)
    end
  end

  def wrap_resolver(resolver) when is_function(resolver, 3) do
    fn source, arguments, resolution ->
      with_error_tracking(fn -> resolver.(source, arguments, resolution) end)
    end
  end

  def wrap_resolver({module, function}) do
    fn source, arguments, resolution ->
      with_error_tracking(fn -> apply(module, function, [source, arguments, resolution]) end)
    end
  end

  def wrap_resolver(resolver), do: resolver

  defp with_error_tracking(function) do
    function.()
  rescue
    error ->
      if span = pop_operation_span() do
        @span.add_error(span, error, __STACKTRACE__)
        @tracer.close_span(span)
      end

      reraise error, __STACKTRACE__
  end

  defp push_operation_span(span) do
    Process.put(
      @operation_span_stack_key,
      [span | Process.get(@operation_span_stack_key, [])]
    )
  end

  defp pop_operation_span do
    case Process.get(@operation_span_stack_key, []) do
      [span | remaining] when remaining == [] ->
        Process.delete(@operation_span_stack_key)
        span

      [span | remaining] ->
        Process.put(@operation_span_stack_key, remaining)
        span

      [] ->
        nil
    end
  end
end
