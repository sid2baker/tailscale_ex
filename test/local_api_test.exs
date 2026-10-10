defmodule Tailscale.LocalAPITest do
  use ExUnit.Case, async: true
  alias Tailscale.LocalAPI
  alias Tailscale.LocalAPI.Frames
  alias Tailscale.Test.UnixHTTP

  test "NDJSON handles every split, multiple frames, blanks and CRLF" do
    data = "{\"State\":2}\r\n\n{\"BrowseToURL\":\"https://example.com/a\"}\n"

    for split <- 0..byte_size(data) do
      <<first::binary-size(^split), last::binary>> = data
      assert {:ok, parser, a} = Frames.feed(%Frames{}, first)
      assert {:ok, %{buffer: ""}, b} = Frames.feed(parser, last)
      assert a ++ b == [%{"State" => 2}, %{"BrowseToURL" => "https://example.com/a"}]
    end
  end

  test "frame limits are per frame and invalid JSON cannot grow the buffer" do
    assert {:ok, %{buffer: ""}, [%{}, %{}]} = Frames.feed(%Frames{limit: 2}, "{}\n{}\n")
    assert {:error, :frame_too_large} = Frames.feed(%Frames{limit: 2}, "123")
    assert {:error, :frame_too_large} = Frames.feed(%Frames{limit: 2}, "123\n")
    assert {:error, :invalid_notification} = Frames.feed(%Frames{}, "invalid\n")
    assert {:error, :invalid_notification} = Frames.feed(%Frames{}, "[]\n")
  end

  test "ordinary Unix HTTP handles fragmented headers and bodies" do
    server = server(["HTTP/1.1 200 O", "K\r\ncontent-length: 7\r\n", "\r\n{\"x", "\":1}"])

    assert {:ok, %{"x" => 1}, _headers} =
             LocalAPI.request([socket: UnixHTTP.socket(server)], "GET", "status")
  end

  test "connection failures, premature closure, timeouts, bad JSON and bounded bodies" do
    assert {:error, :unavailable} =
             LocalAPI.request([socket: "/nonexistent/tsx.sock"], "GET", "status")

    closed = server(["HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{}"])

    assert {:error, :transport} =
             LocalAPI.request([socket: UnixHTTP.socket(closed)], "GET", "status")

    slow = server([100])

    assert {:error, :timeout} =
             LocalAPI.request([socket: UnixHTTP.socket(slow), timeout: 20], "GET", "status")

    invalid = server(["HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nx"])

    assert {:error, :invalid_response} =
             LocalAPI.request([socket: UnixHTTP.socket(invalid)], "GET", "status")

    big = server(["HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\n123"])

    assert {:error, :response_too_large} =
             LocalAPI.request([socket: UnixHTTP.socket(big), max_body: 2], "GET", "status")
  end

  test "Mint bounds incomplete status lines, headers, chunk extensions and trailers" do
    for prefix <- [
          "HTTP/1.1 200 ",
          "HTTP/1.1 200 OK\r\nx-incomplete: ",
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n1;extension=",
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\nx-trailer: "
        ] do
      oversized = String.duplicate("x", 80_000)
      server = server([prefix, 10, oversized, 10_000])

      # The peer stays open beyond the request deadline: neither timeout nor EOF
      # may substitute for Mint enforcing its HTTP syntax limits.
      assert {:error, :transport} =
               LocalAPI.request([socket: UnixHTTP.socket(server)], "GET", "status")
    end
  end

  test "upstream error bodies cannot leak credentials" do
    server = server(["HTTP/1.1 400 Bad\r\ncontent-length: 10\r\n\r\ntskey-leak"])

    assert {:error, {:http, 400}} =
             LocalAPI.request([socket: UnixHTTP.socket(server)], "POST", "start", %{
               "AuthKey" => "tskey-leak"
             })
  end

  test "completed responses survive a Mint error from trailing unexpected bytes" do
    for {status, expected} <- [{200, {:ok, %{}, []}}, {403, {:error, {:http, 403}}}] do
      server = server(["HTTP/1.1 #{status} OK\r\ncontent-length: 2\r\n\r\n{}unexpected"])
      result = LocalAPI.request([socket: UnixHTTP.socket(server)], "GET", "status")

      case expected do
        {:ok, body, _} -> assert {:ok, ^body, _headers} = result
        error -> assert result == error
      end
    end
  end

  test "a valid JSON prefix is not success when HTTP framing is truncated or malformed" do
    for response <- [
          "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n{}",
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\n{}!?"
        ] do
      server = server([response])

      assert {:error, :transport} =
               LocalAPI.request([socket: UnixHTTP.socket(server)], "GET", "status")
    end
  end

  test "large valid bodies are bounded by the body limit, not socket or HTTP chunk size" do
    value = %{"data" => String.duplicate("x", 1_100_000)}
    body = JSON.encode!(value)
    <<first::binary-size(500_000), rest::binary>> = body

    for chunks <- [
          ["HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body],
          [chunked_headers(), chunk(body), "0\r\n\r\n"],
          [chunked_headers(), chunk(first), chunk(rest), "0\r\n\r\n"]
        ] do
      server = server(chunks)

      assert {:ok, ^value, _headers} =
               LocalAPI.request([socket: UnixHTTP.socket(server)], "GET", "status")

      assert {:error, :response_too_large} =
               LocalAPI.request([socket: UnixHTTP.socket(server), max_body: 100], "GET", "status")
    end
  end

  test "notifications parsed before an HTTP error are delivered before disconnect" do
    server = server([[chunked_headers(), chunk("{\"State\":2}\n{"), "invalid-size\r\n"]])
    worker = watch(server)

    assert_receive {:"$gen_call", from, {:notification, ^worker, %{"State" => 2}}}, 1_000
    :gen_statem.reply(from, :ok)
    assert_receive {:watch_ended, ^worker, {:error, :disconnected}}, 1_000
    refute_receive {:"$gen_call", _, {:notification, ^worker, _}}, 50
  end

  test "watch handles split HTTP and NDJSON chunks with backpressure through closure" do
    server =
      server([
        chunked_headers(),
        "4\r",
        "\n{\"St\r\n",
        chunk("ate\":2}\n{\"Sta"),
        chunk("te\":6}\n"),
        "0\r\n\r\n"
      ])

    worker = watch(server)
    assert_receive {:"$gen_call", first, {:notification, ^worker, %{"State" => 2}}}, 1_000
    refute_receive {:"$gen_call", _, {:notification, ^worker, _}}, 50
    :gen_statem.reply(first, :ok)
    assert_receive {:"$gen_call", second, {:notification, ^worker, %{"State" => 6}}}, 1_000
    :gen_statem.reply(second, :ok)
    assert_receive {:watch_ended, ^worker, {:error, :disconnected}}, 1_000
  end

  defp watch(server) do
    consumer = self()
    opts = [socket: UnixHTTP.socket(server)]

    start_supervised!(
      {Task, fn -> send(consumer, {:watch_ended, self(), LocalAPI.watch(opts, consumer)}) end},
      id: make_ref()
    )
  end

  defp chunked_headers, do: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
  defp chunk(data), do: [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"]

  defp server(chunks) do
    start_supervised!({UnixHTTP, handler: fn _request, state -> {{:raw, chunks}, state} end},
      id: make_ref()
    )
  end
end
