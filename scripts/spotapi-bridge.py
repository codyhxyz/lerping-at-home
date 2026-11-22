#!/usr/bin/env python3
"""Optional SpotAPI adapter for LerpPulse (Python 3.11+).

Install `spotapi` in the selected interpreter, or `spotapi[keyring]` to reuse
an existing Connect profile. No login is opened, no playback commands are
sent, and no session material is included in output. The public lookup mode
borrows no Spotify account, even when SPOTIFY_COOKIE is set.
"""

import argparse
import asyncio
import json
import os
import re
import signal
import sys
import tempfile
import time
from pathlib import Path


def text(value):
    return value[:1024] if isinstance(value, str) else ""


def image_url(value):
    value = text(value)
    if re.fullmatch(r"spotify:image:[a-f0-9]{40}", value, re.IGNORECASE):
        return "https://i.scdn.co/image/" + value.split(":")[-1]
    return value


async def enrich(value):
    from spotapi import Public

    if not value.startswith(("spotify:track:", "https://open.spotify.com/")):
        hits = (await Public.search(value, limit=1)).tracks
        if not hits:
            return None
        value = hits[0].uri
    detail = await Public.get_track(value)
    album = detail.album_of_track
    cover = album.cover_art if album else None
    artists = detail.first_artist.items if detail.first_artist else []
    artwork = max(cover.sources, key=lambda s: (s.width or 0) * (s.height or 0), default=None) if cover else None
    return {
        "trackUri": text(detail.uri),
        "title": text(detail.name),
        "artist": text(artists[0].profile.name) if artists and artists[0].profile else "",
        "album": text(album.name) if album else "",
        "image_url": image_url(artwork.url) if artwork else "",
    }


def connect_value(state):
    track = state.track if state else None
    return {
        "playing": bool(track and state.is_playing and not state.is_paused),
        "trackUri": text(track.uri) if track else "",
        "title": text(track.name) if track else "",
        "artist": text(track.artist) if track else "",
        "album": text(track.album) if track else "",
        "image_url": image_url(track.image_url) if track else "",
    }


def emit(payload, output=None):
    record = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    if output is None:
        print(record, end="", flush=True)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    # NamedTemporaryFile creates mode 0600 and os.replace is atomic.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent,
                                     prefix=".spotify-connect-", delete=False) as f:
        tmp = Path(f.name)
        try:
            f.write(record)
            f.close()
            os.replace(tmp, output)
        finally:
            tmp.unlink(missing_ok=True)


async def observe(profile, output):
    from spotapi import AsyncClient, PlayerStatus, SavedSession

    cookie = os.environ.get("SPOTIFY_COOKIE", "").strip() if profile is None else ""
    client = await (AsyncClient.from_cookies(cookie) if cookie else SavedSession(profile or "default").open())
    async with client:
        status = PlayerStatus(client, name="LerpPulse")
        observer = asyncio.create_task(status.start())
        previous = None
        heartbeat = 0.0
        try:
            while not observer.done():
                if status.is_ready or previous is not None:
                    value = connect_value(status.state if status.is_ready else None)
                    now = time.monotonic()
                    if value != previous or (output is not None and now >= heartbeat):
                        emit({**value, "updatedAt": time.time()}, output)
                        previous = value
                        heartbeat = now + 5
                await asyncio.wait({observer}, timeout=1)
            observer.result()
        finally:
            observer.cancel()
            await asyncio.gather(observer, return_exceptions=True)


async def watch(profile, output, parent_pid):
    async def parent_ends():
        while parent_pid is None or parent_pid == os.getppid():
            await asyncio.sleep(1)

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    observer = asyncio.create_task(observe(profile, output))
    tasks = (observer, asyncio.create_task(parent_ends()), asyncio.create_task(stop.wait()))
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        if observer in done:
            observer.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--enrich-track", metavar="SPOTIFY_URI_OR_QUERY")
    modes.add_argument("--watch-connect", action="store_true")
    parser.add_argument("--profile", help="saved Connect profile; overrides SPOTIFY_COOKIE")
    parser.add_argument("--output", type=Path, help="atomically update this JSON file instead of writing NDJSON")
    parser.add_argument("--parent-pid", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.watch_connect and (args.output or args.profile or args.parent_pid):
        parser.error("--output, --profile and --parent-pid require --watch-connect")
    if sys.version_info < (3, 11):
        print("SpotAPI bridge needs Python 3.11 or later", file=sys.stderr)
        return 2
    try:
        if args.watch_connect:
            asyncio.run(watch(args.profile, args.output, args.parent_pid))
        else:
            result = asyncio.run(asyncio.wait_for(enrich(args.enrich_track), timeout=15))
            if result is None:
                return 1
            emit(result)
    except (Exception, KeyboardInterrupt) as error:
        # Third-party exception messages and tracebacks can include auth URLs.
        print(f"SpotAPI bridge unavailable ({type(error).__name__})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
