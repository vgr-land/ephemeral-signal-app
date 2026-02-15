# Ephemeral Signal App

## Overview

This code base creates a MacOS app that launches a Docker container running the Linux Signal App. The goal is to have process isolation and no artifacts of the Signal installation on the host OS. Despite MacOS running on ARM, the AMD64 package of the Linux Signal app is more stable which is why this app is running on a AMD64 container. 

On launch the app confirms that Docker is installed, and uses Docker Compose to launch a container with Docker installed fronted by VNC. The app connects to the container using a built in browser session to the NoVNC session. 

Notifications are evented via Docker logs and picked up by the wrapper application which creates app badges. Details of the event remain inside the Docker container. 

## Code 

This code is heavily LLM generated. I have never written a swift application in my life. I did try to add some sensible Docker configurations. This includes limiting ports to the localhost, implementing SSL so that the app communicates to the container on the local host via SSL, and not pinning to any specific version besides the operating system. This should allow this application to remain current until Ubuntu 24.04 goes EOL in 2029. 

The notification mechanism is an absolute hack but I couldn't figure out a better way. 

## Possible Improvements 

### Clipboard

In its current configuration it's not possible to copy and paste to and from the container. This is both a feature and a constraint. The container is functionally isolated from the host, even at the clipboard level. 

### File Mounts

The container doesn't mount any host folders so it's not possible to save files to the host from the container, or upload files from the host to the container. 

### Audio and Video

I'm not sure how well VNC over a browser would react to audio and video streaming. It's not a function I use often and when I do my phone is fine. 