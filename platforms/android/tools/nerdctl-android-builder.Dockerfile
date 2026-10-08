FROM eclipse-temurin:17-jdk-jammy

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
