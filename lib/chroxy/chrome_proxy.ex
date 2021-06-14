defmodule Chroxy.ChromeProxy do
  @moduledoc """
  Process which establishes a single proxied websocket connection
  to an underlying chrome browser page remote debugging websocket.

  Upon initialisation, the chrome proxy signal the `Chroxy.ProxyListener`
  to accept a TCP connection.  The `Chroxy.ProxyListener` will initialise a
  `Chroxy.ProxyServer` to manage the connection between the upstream client
  and the downstream chrome remote debugging websocket.

  When either the upstream or downstream connections close, the `down/2`
  behaviours `Chroxy.ProxyServer.Hook` callback is invoked, allowing the
  `Chroxy.ChromeProxy` to close the chrome page.
  """
  use GenServer

  require Logger

  @behaviour Chroxy.ProxyServer.Hook

  ##
  # API

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5000,
      type: :worker
    }
  end

  @doc """
  Spawns `Chroxy.ChromeProxy` process.

  Keyword `args`:
  - `:chrome` - pid of a `Chroxy.ChromeServer` process.
  """
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Starts a chrome page, and returns a websocket connection
  routed via the underlying proxy.
  """
  def chrome_connection(ref) do
    GenServer.call(ref, :chrome_connection)
  end

  ##
  # Proxy Hook Callbacks

  @doc """
  `Chroxy.ProxyServer` Callback Hook
  Called when upstream connection is established to ProxyServer.
  Will return downstream connection information of the Chrome instance.
  """
  def up(ref, proxy_state) do
    GenServer.call(ref, {:up, proxy_state})
  end

  @doc """
  `Chroxy.ProxyServer` Callback Hook
  Called when upstream or downstream connections are closed.
  Will close the chrome page and shutdown this process.
  """
  def down(ref, proxy_state) do
    GenServer.cast(ref, {:down, proxy_state})
  end

  @doc """
  Extract Chrome `page_id` from url.
  """
  def page_id({:url, url}) do
    url
    |> String.split("/")
    |> List.last()
  end

  @doc """
  Extract Chrome `page_id` from http request.
  """
  def page_id({:http_request, data}) do
    data
    |> String.split(" HTTP")
    |> List.first()
    |> String.split("GET /devtools/page/")
    |> Enum.at(1)
  end

  ##
  # GenServer Callbacks

  @doc false
  def init(args) do
    chrome_pid = Keyword.get(args, :chrome)
    # We don't need to terminate the underlying proxy if the chrome browser process
    # goes down as:
    #   1. It may not have been openned yet when client is yet to connect.
    #   2. The socket close signal when browser is terminated will terminate the proxy.
    # In the event it has not been established yet, we will want to terminate
    # this process, alas it should be linked.
    Process.flag(:trap_exit, true)
    Process.link(chrome_pid)

    {:ok, %{chrome: chrome_pid, page: nil, proxy_opts: nil}}
  end

  @doc false
  def handle_call(:chrome_connection, _from, state = %{chrome: chrome, page: nil}) do
    # Create a new page
    page = new_page(chrome)

    # Register page into `ProxyRouter` for dynamic lookup
    Chroxy.ProxyRouter.put(page["id"], self())

    # Get the websocket host:port for the page and pass to the proxy listener
    # directly in order to set the downstream connection proxy process when
    # a upstream client connects. (Note: no need to use `up/2` callback as we
    # have the downstream information available at tcp listener accept time).
    uri = page["webSocketDebuggerUrl"] |> URI.parse()

    # Asynchronously signal the listen to accept connection, which will spawn a
    # ProxyServer to handle the communications.  The ProxyServer will be passed
    # the lookup function which will find downstream connection options based on
    # the incomming request
    Chroxy.ProxyListener.accept(
      dyn_hook: fn req ->
        %{
          mod: Chroxy.ChromeProxy,
          ref:
            page_id({:http_request, req})
            |> Chroxy.ProxyRouter.get()
        }
      end
    )

    proxy_websocket = proxy_websocket_addr(page)

    {:reply, proxy_websocket,
     %{
       state
       | page: page,
         proxy_opts: [
           downstream_host: uri.host |> String.to_charlist(),
           downstream_port: uri.port
         ]
     }}
  end

  @doc false
  def handle_call(:chrome_connection, _from, state = %{page: page}) do
    proxy_websocket_url = proxy_websocket_addr(page)
    {:reply, proxy_websocket_url, state}
  end

  @doc false
  def handle_call({:up, _proxy_state}, _from, state = %{proxy_opts: proxy_opts}) do
    {:reply, proxy_opts, state}
  end

  @doc false
  def handle_cast({:down, _proxy_state}, state = %{chrome: _chrome, page: _page}) do
    # Logger.info("Proxy connection down - closing page")
    # # Close the page when connection is down, unless chrome process has died
    # # which is a reason for which the connection could be down
    # if Process.alive?(chrome) do
    #   Chroxy.ChromeServer.close_page(chrome, page)
    #   Chroxy.ProxyRouter.delete(page["id"])
    # end
    # terminate this process, as underlying proxy connections have been closed
    {:stop, :normal, state}
  end

  defp proxy_websocket_addr(%{"webSocketDebuggerUrl" => websocket}) do
    # Change host and port in websocket address to that of the proxy
    proxy_opts = Application.get_env(:chroxy, Chroxy.ProxyListener)
    proxy_host = Keyword.get(proxy_opts, :host)
    proxy_port = Keyword.get(proxy_opts, :port)
    uri = URI.parse(websocket)

    proxy_websocket =
      websocket
      |> String.replace(Integer.to_string(uri.port), proxy_port)
      |> String.replace(uri.host, proxy_host)

    proxy_websocket
  end

  defp new_page(chrome) do
    case Chroxy.ChromeServer.new_page(chrome) do
      :not_ready ->
        Logger.debug(
          "Failed to obtain new page, ChromeServer [#{inspect(chrome)}] not ready, retrying..."
        )

        Chroxy.ChromeServer.ready(chrome)
        new_page(chrome)

      page ->
        Logger.debug("Obtained new page from ChromeServer [#{inspect(chrome)}]")
        page
    end
  end
end
