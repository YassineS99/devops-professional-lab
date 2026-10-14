from flask import Flask, render_template, request, make_response
from redis import Redis
from redis.backoff import NoBackoff
from redis.retry import Retry
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
import os
import socket
import random
import json
import logging

option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
hostname = socket.gethostname()

# Redis calls are bounded: short socket timeouts, no client retries, and an
# overall deadline. Socket timeouts do not cover DNS lookups, so each call
# runs in a worker thread and the request stops waiting at the deadline.
REDIS_DEADLINE = float(os.getenv('REDIS_DEADLINE', '3'))
_pool = ThreadPoolExecutor(max_workers=8)

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)


def new_redis():
    return Redis(host="redis", db=0, socket_timeout=1,
                 socket_connect_timeout=1, retry=Retry(NoBackoff(), 0))


def redis_call(fn, deadline=REDIS_DEADLINE):
    """Run fn(redis_client) with an overall deadline. Raises on failure."""
    fut = _pool.submit(lambda: fn(new_redis()))
    try:
        return fut.result(timeout=deadline)
    except FutureTimeout:
        raise TimeoutError("redis call exceeded %.1fs" % deadline)


@app.route("/healthz")
def healthz():
    # Liveness: the process is up and serving. Does not touch dependencies.
    return "ok\n", 200


@app.route("/ready")
def ready():
    # Readiness: the app can do its job, which needs Redis.
    try:
        redis_call(lambda r: r.ping(), deadline=2)
    except Exception as e:
        app.logger.warning("not ready: redis check failed (%s)", type(e).__name__)
        return "redis unavailable\n", 503
    return "ready\n", 200


@app.route("/", methods=['POST', 'GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None

    if request.method == 'POST':
        vote = request.form['vote']
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        try:
            redis_call(lambda r: r.rpush('votes', data))
        except Exception as e:
            app.logger.error("vote for %s NOT recorded: redis unavailable (%s)",
                             vote, type(e).__name__)
            return make_response("Voting is temporarily unavailable. Please try again.\n", 503)
        app.logger.info('Recorded vote for %s', vote)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80, debug=True, threaded=True)
