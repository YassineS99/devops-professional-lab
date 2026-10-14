# Simulated bad release: fails while the application is initializing.
import os

REQUIRED = os.environ["REDIS_URL"]   # not set here, so this raises KeyError
