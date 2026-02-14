from __future__ import annotations

from types import SimpleNamespace

from tools import web_search


def test_web_search_parses_duckduckgo_html(monkeypatch) -> None:
    html = """
    <html><body>
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage">Example <b>Title</b></a>
      <a class="result__snippet" href="#">A <b>short</b> snippet.</a>
    </body></html>
    """

    def fake_get(*args, **kwargs):
        return SimpleNamespace(status_code=200, text=html)

    monkeypatch.setattr(web_search.httpx, "get", fake_get)

    output, _ = web_search.handle_web_search({"query": "example", "max_results": 1}, {})
    assert "Web results for: example" in output
    assert "1. Example Title" in output
    assert "URL: https://example.com/page" in output
    assert "Snippet: A short snippet." in output


def test_web_search_no_results(monkeypatch) -> None:
    def fake_get(*args, **kwargs):
        return SimpleNamespace(status_code=200, text="<html><body>empty</body></html>")

    monkeypatch.setattr(web_search.httpx, "get", fake_get)

    output, _ = web_search.handle_web_search({"query": "missing"}, {})
    assert "No web results found for query: missing" in output
