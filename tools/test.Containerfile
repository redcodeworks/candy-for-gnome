# SPDX-License-Identifier: MIT
# Image for tools/test.sh: Fedora 45 (the committed CSS was generated against Fedora 45's stock GTK and GNOME Shell stylesheets)
# plus the packages in test-packages.txt. It is also the image of the CI `test` job (built by .github/workflows/test-image.yml, which does not run
# this file's CMD): git is in the list because actions/checkout needs it inside the container.
FROM registry.fedoraproject.org/fedora:45
COPY test-packages.txt /tmp/test-packages.txt
RUN dnf -y install $(cat /tmp/test-packages.txt) && dnf clean all
