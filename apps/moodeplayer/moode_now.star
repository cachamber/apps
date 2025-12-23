"""
Applet: Moode Now Playing
Summary: Moode Now Playing
Description: Fetches now-playing information from a Moode player's REST API and displays artist, title and album.
Author: tronbyt
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "canvas", "render")
load("schema.star", "schema")

scale = 2 if canvas.is2x() else 1
FONT = "terminus-18" if scale == 2 else "tb-8"
DEFAULT_URL = "http://moode"
DEFAULT_ENDPOINT = "/command?cmd=get_currentsong"
DEFAULT_COLOR = "#22ff7b"

SCROLL_TOGETHER = "together"
SCROLL_SEPARATE = "separate"
SCROLL_DISABLED = "disabled"
DEFAULT_SCROLL = SCROLL_TOGETHER

def extract_fields(data):
    # Accept several common shapes returned by music players
    result = {
        "artist": None,
        "title": None,
        "album": None,
        "coverurl": None,
    }

    if not data:
        return result

    # If top-level keys exist
    for k in ["artist", "Artist", "ARTIST"]:
        if k in data:
            result["artist"] = data[k]
            break

    for k in ["title", "Title", "track", "Track", "song"]:
        if k in data:
            result["title"] = data[k]
            break

    for k in ["album", "Album"]:
        if k in data:
            result["album"] = data[k]
            break

    # common cover keys
    for k in ["coverurl", "coverUrl", "coverURL", "cover", "cover_url", "albumArt", "artwork_url", "image", "entity_picture"]:
        if k in data:
            result["coverurl"] = data[k]
            break

    # Some APIs nest metadata under "now_playing" or "nowplaying"
    for nest in ["now_playing", "nowplaying", "nowPlaying"]:
        if nest in data and data[nest]:
            nested = data[nest]
            for k in ["artist", "Artist", "ARTIST"]:
                if k in nested:
                    result["artist"] = nested[k]
                    break
            for k in ["title", "Title", "track", "Track", "song"]:
                if k in nested:
                    result["title"] = nested[k]
                    break
            for k in ["album", "Album"]:
                if k in nested:
                    result["album"] = nested[k]
                    break

            for k in ["coverurl", "coverUrl", "coverURL", "cover", "cover_url", "albumArt", "artwork_url", "image", "entity_picture"]:
                if k in nested:
                    result["coverurl"] = nested[k]
                    break

    # Sometimes the payload is a single string like "Artist - Title"
    if not result["artist"] and not result["title"] and type(data) == "string":
        s = data
        if " - " in s:
            parts = s.split(" - ", 1)
            result["artist"] = parts[0]
            result["title"] = parts[1]

    # no cover available for plain text payloads

    return result

def fetch_now_playing(base_url, endpoint):
    url = base_url.rstrip("/") + endpoint
    resp = http.get(url = url, ttl_seconds = 10)

    # Respect non-200 responses
    if resp.status_code != 200:
        return {"artist": None, "title": None, "album": None, "coverurl": None}
    body = resp.body()
    s = body if type(body) == "string" else str(body)
    s_stripped = s.lstrip()

    # Try to decode JSON if it looks like JSON
    if s_stripped.startswith("{") or s_stripped.startswith("[") or s_stripped.startswith('"'):
        parsed = json.decode(body)
        return extract_fields(parsed)

    # simple heuristic for plain text like "Artist - Title"
    if " - " in s:
        parts = s.split(" - ", 1)
        return {"artist": parts[0], "title": parts[1], "album": None, "coverurl": None}

    return {"artist": None, "title": None, "album": None, "coverurl": None}

def render_root(artist, title, album, colour, media_image = None, show_art = True):
    # Build fields similar to ha_now_playing: title (colored), then artist/album
    artist_text = artist or ""
    title_text = title or "No title"
    album_text = album or ""

    scale = 2 if canvas.is2x() else 1
    font = FONT
    scroll = DEFAULT_SCROLL
    pad = 2 * scale

    def render_text_widget(content, width, color = "", font = "", scroll = DEFAULT_SCROLL):
        text = render.Text(
            content = content,
            color = color,
            font = font,
        )

        if scroll == SCROLL_DISABLED:
            return text

        offset = width if scroll == SCROLL_TOGETHER else 0
        return render.Marquee(
            width = width,
            offset_start = offset,
            offset_end = offset,
            child = text,
        )

    secondary_width = 41 * scale if show_art else 60 * scale
    image_size = 36 if scale == 2 else 17 * scale

    return render.Root(
        delay = 50 if scale == 1 else 25,
        child = render.Column(
            children = [
                render.Padding(
                    pad = (pad, 2, 0 if show_art else pad, 0),
                    child = render_text_widget(title_text, 60 * scale, color = colour, font = font, scroll = scroll),
                ),
                render.Padding(
                    pad = (pad, 2, 0 if show_art else pad, 0),
                    child = render.Row(
                        children = [
                            render.Image(
                                src = media_image,
                                height = image_size,
                                width = image_size,
                            ) if (show_art and media_image) else None,
                            render.Padding(
                                pad = (pad, 0, 0, 0) if show_art else 0,
                                child = render.Column(children = [
                                    render_text_widget(artist_text, width = secondary_width, font = font, scroll = scroll),
                                    render_text_widget(album_text, width = secondary_width, color = "#cccccc", font = font, scroll = scroll),
                                ]),
                            ),
                        ],
                    ),
                ),
            ],
        ),
    )

def main(config):
    base_url = config.get("base_url", DEFAULT_URL)
    endpoint = config.get("endpoint", DEFAULT_ENDPOINT)
    colour = config.get("colour", DEFAULT_COLOR)

    # Try the user-specified endpoint first, then a few common variants.
    candidates = [endpoint, "/command?cmd=get_currentsong", "/api/nowplaying", "/nowplaying", "/now_playing", "/status"]
    data = None
    for e in candidates:
        data = fetch_now_playing(base_url, e)

        # If we found a title or artist, accept
        if data and (data.get("title") or data.get("artist")):
            break

    artist = None
    title = None
    album = None
    coverurl = None
    if data:
        artist = data.get("artist")
        title = data.get("title")
        album = data.get("album")
        coverurl = data.get("coverurl")

    media_image = None

    # If a coverurl is provided, build a URL by appending it to DEFAULT_URL and fetch the image
    if coverurl:
        # ensure we append coverurl to the configured base_url
        suffix = coverurl if coverurl.startswith("/") else "/" + coverurl
        img_url = base_url.rstrip("/") + suffix
        res = http.get(img_url, ttl_seconds = 600)
        if res.status_code == 200:
            media_image = res.body()

    return render_root(artist, title, album, colour, media_image = media_image, show_art = True)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "base_url",
                name = "Base URL",
                desc = "Base URL of your Moode player (e.g. http://moode.local)",
                default = DEFAULT_URL,
                icon = "server",
            ),
            schema.Text(
                id = "endpoint",
                name = "Endpoint",
                desc = "REST endpoint path to fetch now-playing (default tries common paths)",
                default = DEFAULT_ENDPOINT,
                icon = "link",
            ),
            schema.Color(
                id = "colour",
                name = "Colour",
                desc = "Main text colour",
                default = DEFAULT_COLOR,
                icon = "brush",
            ),
        ],
    )
