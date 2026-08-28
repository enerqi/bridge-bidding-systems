@echo off
rem Run locust in docker -- mainly for the ease of spinning up multiple load injector processes with
rem the --processes arg, which does not work on Windows.
rem
rem The gc-docker-images/locust image is based on locustio/locust and includes `uv` and
rem `python-dotenv`. Mounts this directory at /locust and runs `uv sync` before locust.
rem
rem The container reaches a server running on THIS machine at host.docker.internal, not 127.0.0.1 --
rem 127.0.0.1 inside the container is the container.
rem
rem Usage:
rem     docker-run-locust -f /locust/locustfiles --host http://host.docker.internal:5008 -u 400 -r 20 -t 300 --headless --processes 4
docker run -it --rm ^
    -e UV_INDEX_GITLAB_USERNAME=%UV_INDEX_GITLAB_USERNAME% ^
    -e UV_INDEX_GITLAB_PASSWORD=%UV_INDEX_GITLAB_PASSWORD% ^
    -e UV_PROJECT_ENVIRONMENT=/opt/venv ^
    -e VIRTUAL_ENV=/opt/venv ^
    -e DSQUIZ_PERF_HOST=%DSQUIZ_PERF_HOST% ^
    -e SCALE=%SCALE% ^
    --add-host=host.docker.internal:host-gateway ^
    --mount type=bind,src=.,dst=/locust ^
    --entrypoint="" ^
    git.int.gigaclear.net:5005/gis/gc-docker-images/locust:1.0 ^
    /bin/bash -c "uv sync && locust %*"
