FROM --platform=linux/amd64 eclipse-temurin:17.0.20.1_1-jdk-jammy@sha256:8d242405506ad1085e39f1ca80ec76f0812f61073efe76129607e39f043ccbb9

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		build-essential \
		cmake \
		curl \
		file \
		git \
		nasm \
		ninja-build \
		perl \
		pkg-config \
		python3 \
		unzip \
		zip \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
