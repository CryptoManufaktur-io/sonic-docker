# Overview

Docker Compose for Sonic RPC nodes

`cp default.env .env`, then `nano .env` and adjust values.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

If you want the RPC ports exposed locally, use `rpc-shared.yml` in `COMPOSE_FILE` inside `.env`.

The `./sonicd` script can be used as a quick-start:

`./sonicd install` brings in docker-ce, if you don't have Docker installed already.

`cp default.env .env`

`nano .env` and adjust variables as needed

`./sonicd up`

To update the software, run `./sonicd update` and then `./sonicd up`

# Version

This is Sonic Docker v1.0.1
