defmodule FakeHTTPoisonBase do
  use TestAgent, %{raise: false}

  def set_raise(value) do
    Agent.update(__MODULE__, fn state -> %{state | raise: value} end)
  end

  def should_raise? do
    if alive?() do
      Agent.get(__MODULE__, & &1[:raise])
    else
      false
    end
  end

  defmacro __using__(_opts) do
    quote do
      def process_request_url(url) do
        url = to_string(url)

        if String.contains?(url, "://"), do: url, else: "http://" <> url
      end

      def request(_request) do
        if FakeHTTPoisonBase.should_raise?() do
          raise RuntimeError, "Simulated HTTP error"
        else
          {:ok, :fake_response}
        end
      end

      def request(method, url, body \\ "", headers \\ [], options \\ []) do
        request(%HTTPoison.Request{
          method: method,
          url: url,
          body: body,
          headers: headers,
          options: options
        })
      end

      def request!(request) do
        case request(request) do
          {:ok, response} -> response
          {:error, reason} -> raise RuntimeError, "Simulated HTTP error: #{inspect(reason)}"
        end
      end

      def request!(method, url, body \\ "", headers \\ [], options \\ []) do
        request!(%HTTPoison.Request{
          method: method,
          url: url,
          body: body,
          headers: headers,
          options: options
        })
      end

      defoverridable process_request_url: 1, request: 1, request: 5, request!: 1, request!: 5
    end
  end
end
