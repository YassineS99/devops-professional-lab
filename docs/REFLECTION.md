# Reflection

If I were responsible for this application in a real engineering team, what could go wrong, how
would I detect it, and how would I recover?

## Risk 1: A bad release

I tested this with an image that crashes on startup because a required setting is missing. The
health gate caught it fast: the deploy command failed after 4 seconds because the container never
became healthy. The logs showed the cause straight away, a KeyError for REDIS_URL, before any
user request was served.

Recovery was a rollback to the previous image by its digest, which took 7 seconds. The health
checks passed again and the vote saved before the release was still there. I deploy by digest
because a tag can be moved, and a digest always means the same image.

What is still weak: I run only one copy of the app, so the old container is replaced before the
new one is proven. Users got no response until the rollback finished. I did not measure how long
that gap was.

## Risk 2: Redis fails while the app still looks healthy

In my first Compose version, when Redis stopped, voting hung for about 31 seconds and then the
connection dropped, while Docker still showed the app as healthy. The health check only requested
the home page, which never touches Redis. One Redis call with a 5 second timeout took 46 seconds,
so the timeout did not protect anything.

I fixed it with a /ready check that pings Redis, short limits on every Redis call, and a clear
503 error for votes that cannot be saved. Now the check fails in 1 to 3 seconds, the container
turns unhealthy, and everything recovers within about 10 seconds after Redis comes back, without
restarting the app. Votes sent during the outage are rejected, not saved for later.

The lesson that surprised me most: a container can say healthy while the service is broken.
Healthy only means the check I wrote passed, so the check must test what users need. My CI now
starts the whole stack on every pull request, checks /ready, and proves that readiness fails when
Redis is down.

## What I would build next

Automatic rollback when the health gate fails. Today I run the rollback by hand with a script. The
automatic version would record the running image digest before the deploy, run the deploy with
the health gate, and if the gate fails, save the logs first and then redeploy the recorded
digest. Saving the logs first matters, because a rollback removes the crashed container and its
logs. I would only roll back when the failure starts right after a deploy. If Redis is down,
rolling back the app would not help.
