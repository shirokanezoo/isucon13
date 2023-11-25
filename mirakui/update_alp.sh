#!/bin/bash -ex
~/alp ltsv --file=/var/log/nginx/access.log --format=html -m '/api/player/competition/[^/]+/ranking$,/api/player/player/[^/]+$,/api/organizer/competition/[^/]+/finish$,/api/organizer/competition/[^/]+/score$,/api/organizer/player/[^/]+/disqualified$' > ~/public_html/alp.html
