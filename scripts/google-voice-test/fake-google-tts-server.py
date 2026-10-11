#!/usr/bin/python3
"""
A stand-in for Google Cloud Text-to-Speech's REST API, used by
scripts/test-google-voice.sh to exercise GoogleChirpSpeechSynthesisProvider
without a real API key or internet.

The API key (X-Goog-Api-Key header) picks the behavior:
  key-ok            200 with a short silent WAV in "audioContent" (base64)
  key-api-disabled  403 "...API has not been used in project ... or it is disabled"
  key-billing       403 "This API method requires billing to be enabled"
  key-bad           400 invalid voice
  key-busy          429 RESOURCE_EXHAUSTED (rate limit — should NOT disable Google)
  key-slow          waits 7s before answering (longer than the provider's timeout)

The body of the last successful request is written to last-request.json
next to the port file, so the test can check what the app sent.
Usage: fake-google-tts-server.py <directory for port + last-request files>
"""

import base64
import io
import json
import os
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIRECTORY = sys.argv[1]


def make_silent_wav_bytes(seconds=0.25, sample_rate=24000):
    wav_buffer = io.BytesIO()
    with wave.open(wav_buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(b"\x00\x00" * int(seconds * sample_rate))
    return wav_buffer.getvalue()


def google_error(code, status, message):
    return code, {"error": {"code": code, "message": message, "status": status}}


class FakeGoogleTextToSpeech(BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def do_HEAD(self):
        # The provider's connection warm-up.
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        request_body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        api_key = self.headers.get("X-Goog-Api-Key", "")

        if self.path != "/v1/text:synthesize":
            return self.respond(*google_error(404, "NOT_FOUND", "unknown path " + self.path))
        if api_key == "key-api-disabled":
            return self.respond(*google_error(403, "PERMISSION_DENIED",
                "Cloud Text-to-Speech API has not been used in project 123 before or it is disabled."))
        if api_key == "key-billing":
            return self.respond(*google_error(403, "PERMISSION_DENIED",
                "This API method requires billing to be enabled. Please enable billing on project 123."))
        if api_key == "key-bad":
            return self.respond(*google_error(400, "INVALID_ARGUMENT", "Voice 'en-US-Chirp3-HD-Nope' does not exist."))
        if api_key == "key-busy":
            return self.respond(*google_error(429, "RESOURCE_EXHAUSTED", "Quota exceeded for requests per minute."))
        if api_key == "key-slow":
            time.sleep(7)
        if api_key not in ("key-ok", "key-slow"):
            return self.respond(*google_error(400, "INVALID_ARGUMENT", "API key not valid."))

        with open(os.path.join(STATE_DIRECTORY, "last-request.json"), "wb") as last_request_file:
            last_request_file.write(request_body)
        self.respond(200, {"audioContent": base64.b64encode(make_silent_wav_bytes()).decode()})

    def respond(self, status_code, response_object):
        response_bytes = json.dumps(response_object).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response_bytes)))
        self.end_headers()
        try:
            self.wfile.write(response_bytes)
        except BrokenPipeError:
            pass  # the client gave up (the timeout test)


server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGoogleTextToSpeech)
with open(os.path.join(STATE_DIRECTORY, "port"), "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
