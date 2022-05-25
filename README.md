# kubernetes-vault-cluster

[![GitHub license](https://img.shields.io/github/license/hosein-yousefii/kubernetes-vault-cluster)](https://github.com/hosein-yousefii/kubernetes-vault-cluster/blob/master/LICENSE)
![LinkedIn](https://shields.io/badge/style-hoseinyousefi-black?logo=linkedin&label=LinkedIn&link=https://www.linkedin.com/in/hoseinyousefi)

vault cluster in kubernetes integrated with consul cluster.

Use this repository To implement a simple Vault cluster which is integrated to Consul cluster as back storage, for test purpose.

## What is Vault?

Secure, store and tightly control access to tokens, passwords, certificates, encryption keys for protecting secrets and other sensitive data using a UI, CLI, or HTTP API.

## What is Consul?

Consul uses service identities and traditional networking practices to help organizations securely connect applications running in any environment.

## Why this repository?

It's simple to use and understand with simple configuration.

# Get started:

Clone the repository where you have access to kubectl.

Then run the script:

```
./vault-cluster.sh

```

This script will deploy consul cluster first, then vault. Also, init and unseal vault and store keys to the current directory in "vault-cluster-keys.txt".

!!Attention!!

I've used GlusterFS as storage class in kubernetes, you should change it to what you are using. The configuration is in "vault/deploy.yaml" and "consul/deploy.yaml" last section which is "volumeClaimTemplates:" so, change "storageClassName: "glusterfs"" to your cluster storage class.


# How to contribute:

Several things need to be implemented like: TLS, auto-unseal and etc. You are more than welcome to contribute to this project.

Copyright 2021 Hosein Yousefi <yousefi.hosein.o@gmail.com>


