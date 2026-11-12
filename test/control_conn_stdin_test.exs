defmodule Sprites.ControlConnStdinTest do
  use ExUnit.Case, async: true

  alias Sprites.{Command, ControlConn, Sprite}

  @canary "stdin-canary-secret"
  @token "token-canary-secret"

  # Runs a real ControlConn process with an invalid connection so that
  # :gun.ws_send raises inside the ControlConn callback.
  def run_conn_loop(parent) do
    :proc_lib.init_ack(parent, {:ok, self()})
    state = %{conn: "not-a-connection", stream_ref: make_ref(), owner: nil, op_active: false}
    Process.flag(:sensitive, true)
    :gen_server.enter_loop(ControlConn, [], state)
  end

  def run_command_loop(parent, conn_pid) do
    :proc_lib.init_ack(parent, {:ok, self()})

    state = %{
      sensitive: true,
      owner: self(),
      ref: make_ref(),
      tty_mode: false,
      conn: nil,
      stream_ref: nil,
      exit_code: nil,
      token: @token,
      sprite: Sprite.new(Sprites.new(@token), "control-test"),
      url: nil,
      using_control: true,
      control_conn: conn_pid
    }

    :gen_server.enter_loop(Command, [], state)
  end

  defp start_conn, do: :proc_lib.start(__MODULE__, :run_conn_loop, [self()])

  test "write_stdin reports a dispatch failure without crashing or logging stdin" do
    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        {:ok, conn} = start_conn()
        assert {:error, :write_failed} = ControlConn.write_stdin(conn, @canary)
        assert Process.alive?(conn)

        status = :sys.get_status(conn)
        refute inspect(status, limit: :infinity) =~ @canary
        refute inspect(status, limit: :infinity) =~ @token
        Process.exit(conn, :kill)
        Process.sleep(50)
      end)

    refute log =~ @canary
    refute log =~ @token
  end

  test "write_stdin to a dead connection returns write_failed" do
    {:ok, conn} = start_conn()
    Process.exit(conn, :kill)
    Process.sleep(20)
    assert {:error, :write_failed} = ControlConn.write_stdin(conn, @canary)
  end

  test "Command in control mode returns write_failed across the real ControlConn boundary" do
    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        {:ok, conn} = start_conn()
        {:ok, cmd} = :proc_lib.start(__MODULE__, :run_command_loop, [self(), conn])

        assert {:error, :write_failed} = GenServer.call(cmd, {:write_stdin, @canary})
        assert Process.alive?(cmd)
        assert Process.alive?(conn)

        for pid <- [cmd, conn] do
          refute inspect(:sys.get_status(pid), limit: :infinity) =~ @canary
          refute inspect(:sys.get_status(pid), limit: :infinity) =~ @token
        end

        Process.exit(cmd, :kill)
        Process.exit(conn, :kill)
        Process.sleep(50)
      end)

    refute log =~ @canary
    refute log =~ @token
  end

  test "format_status redacts stdin frames, sent data and reason" do
    status =
      ControlConn.format_status(%{
        state: %{},
        message: {:send_data, @canary},
        reason: {:function_clause, [{:gun, :ws_send, [@canary], []}]}
      })

    refute inspect(status, limit: :infinity) =~ @canary

    assert %{message: {:write_stdin, :redacted}} =
             ControlConn.format_status(%{state: %{}, message: {:write_stdin, @canary}})

    assert is_function(&Command.format_status/1)
  end
end
