from tools.bash import handle_run_bash


def test_run_bash_success() -> None:
    output, _ = handle_run_bash({"command": "echo hello"}, {})
    assert "exit_code: 0" in output
    assert "stdout:" in output
    assert "hello" in output


def test_run_bash_invalid_cwd() -> None:
    output, _ = handle_run_bash(
        {"command": "echo hello", "cwd": "/definitely/not/a/real/path"},
        {},
    )
    assert "cwd does not exist" in output


def test_run_bash_timeout() -> None:
    output, _ = handle_run_bash(
        {"command": "sleep 2", "timeout_seconds": 1},
        {},
    )
    assert "timeout after 1s" in output
