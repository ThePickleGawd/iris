from __future__ import annotations

import html
import re
from urllib.parse import parse_qs, unquote, urlparse

import httpx

WEB_SEARCH_TOOL = {
    "type": "function",
    "function": {
        "name": "web_search",
        "description": "Search the web and return top results with title, URL, and snippet.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query text.",
                },
                "max_results": {
                    "type": "integer",
                    "description": "Maximum number of results to return (1-10). Default 5.",
                },
            },
            "required": ["query"],
        },
    },
}


def _clean_html_text(raw: str) -> str:
    text = re.sub(r"<[^>]+>", "", raw)
    text = html.unescape(text)
    return " ".join(text.split())


def _normalize_result_url(raw_url: str) -> str:
    # DuckDuckGo result links often come as //duckduckgo.com/l/?uddg=<encoded-target>
    if raw_url.startswith("//"):
        raw_url = f"https:{raw_url}"

    parsed = urlparse(raw_url)
    if "duckduckgo.com" in parsed.netloc and parsed.path.startswith("/l/"):
        qs = parse_qs(parsed.query)
        uddg = qs.get("uddg", [])
        if uddg:
            return unquote(uddg[0])
    return raw_url


def handle_web_search(arguments: dict, context: dict) -> tuple[str, None]:
    query = str(arguments["query"]).strip()
    max_results = int(arguments.get("max_results", 5))
    max_results = max(1, min(max_results, 10))

    try:
        resp = httpx.get(
            "https://html.duckduckgo.com/html/",
            params={"q": query},
            headers={"User-Agent": "Mozilla/5.0 (iris-agent web_search)"},
            timeout=15,
            follow_redirects=True,
        )
    except httpx.HTTPError as exc:
        return f"web_search failed: {exc}", None

    if resp.status_code != 200:
        return f"web_search failed: HTTP {resp.status_code}", None

    page = resp.text

    links = list(
        re.finditer(
            r'<a rel="nofollow" class="result__a" href="(.*?)">(.*?)</a>',
            page,
            re.S,
        )
    )
    snippets = list(
        re.finditer(r'<a class="result__snippet"[^>]*>(.*?)</a>', page, re.S)
    )

    if not links:
        return f"No web results found for query: {query}", None

    lines = [f"Web results for: {query}"]
    count = 0

    for i, link in enumerate(links):
        if count >= max_results:
            break
        raw_url, raw_title = link.group(1), link.group(2)
        url = _normalize_result_url(raw_url)
        title = _clean_html_text(raw_title)
        snippet = _clean_html_text(snippets[i].group(1)) if i < len(snippets) else ""

        lines.append(f"{count + 1}. {title}")
        lines.append(f"   URL: {url}")
        if snippet:
            lines.append(f"   Snippet: {snippet}")
        count += 1

    return "\n".join(lines), None
