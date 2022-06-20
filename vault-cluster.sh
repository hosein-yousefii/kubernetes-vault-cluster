#!/bin/bash
echo """
# Implement Vault cluster integrated with consul cluster in kubernetes.
# written by Hosein Yousefi <yousefi.hosein.o@gmail.com>
"""

if [[ -e .vault-auto-unseal-token.txt ]] 
then
	echo
	echo "The Vault cluster is already installed."
	echo "For reinstalling please remove '.vault-auto-unseal-token.txt' and re execute the script again."
	exit 1
fi

echo "info: cleaning the system"

kubectl delete namespaces vault-cluster &> /dev/null

kubectl delete pv --namespace vault-cluster --all &> /dev/null


################################################################## DEPLOY CONSUL CLUSTER
echo
echo "info: Deploying Consul cluster ..."

kubectl create namespace vault-cluster &> /dev/null
kubectl apply -f consul/cm.yaml &> /dev/null
kubectl apply -f consul/svc.yaml &> /dev/null
kubectl apply -f consul/deploy.yaml &> /dev/null

REPLICAS=$(kubectl get statefulsets.apps --namespace=vault-cluster -o custom-columns=:.spec.replicas consul|tail -1)
REPLICA=$(expr ${REPLICAS} - 1)

echo "info: waiting for the Consul's pods (it might take a few minutes)."

sleep 1m

while [[ ! $(kubectl get po --namespace=vault-cluster --field-selector status.phase=Running|grep consul-$REPLICA ) ]]
do 
	echo -ne .
	sleep 5s
	
done

echo
echo "info: Consul cluster are in running state."

################################################################## DEPLOY VAULT TRANSIT FOR AUTO UNSEALING
echo "##########################################"
echo "info: Deploying Vault transit server ..."

kubectl apply -f auto-unseal/pvc.yaml &> /dev/null
kubectl apply -f auto-unseal/cm.yaml &> /dev/null
kubectl apply -f auto-unseal/svc.yaml &> /dev/null
kubectl apply -f auto-unseal/deploy.yaml &> /dev/null

echo "info: waiting for the Vault transit (auto-unseal) pod (it might take a few minutes)."

while [[ ! $(kubectl get po --namespace=vault-cluster --field-selector status.phase=Running|grep vault-auto-unseal) ]]
do
	echo -ne .
	sleep 2s
	
done

echo
echo "info: Vault transit server successfuly deployed."


################################################################## DEPLOY VAULT CLUSTER
echo "##########################################"
echo "info: Deploying Vault cluster..."

kubectl apply -f vault/cm.yaml &> /dev/null
kubectl apply -f vault/svc.yaml &> /dev/null
kubectl apply -f vault/deploy.yaml &> /dev/null

REPLICAS=$(kubectl get statefulsets.apps --namespace=vault-cluster -o custom-columns=:.spec.replicas vault|tail -1)
REPLICA=$(expr ${REPLICAS} - 1)

echo "info: waiting for the vault's pods (it might take a few minutes)."

while [[ ! $(kubectl get po --namespace=vault-cluster --field-selector status.phase=Running|grep vault-$REPLICA) ]]
do 
	echo -ne .
	sleep 5s
	
done

echo
echo "info: pod's vault are in running state."


################################################################## CONFIGURE VAULT TRANSIT SERVER
echo "##########################################"
echo "info: initializing Vault transit server..."

REPLICASET_TRANSIT_SERVER_NAME=$(kubectl get deployments.apps --namespace=vault-cluster vault-auto-unseal -o custom-columns=:.status.conditions[1].message|awk '{print $2}'|sed 's/"//g')
TRANSIT_SERVER_NAME=$(kubectl describe replicasets.apps --namespace=vault-cluster $REPLICASET_TRANSIT_SERVER_NAME |tail -1|awk '{print $7}')

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault operator init -format=yaml > vault-auto-unseal-keys.txt

echo "info: Unsealing Vault transit server..."

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -2|tail -1|sed 's/- //g') &> /dev/null
kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -3|tail -1|sed 's/- //g') &> /dev/null
kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -4|tail -1|sed 's/- //g') &> /dev/null

VAULT_AUTO_UNSEAL_ROOT_TOKEN=$(grep root_token vault-auto-unseal-keys.txt |awk -F: '{print $2}'|sed 's/ //g')

sleep 3s

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault login -tls-skip-verify ${VAULT_AUTO_UNSEAL_ROOT_TOKEN} &> /dev/null

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault secrets enable transit &> /dev/null

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault write -f transit/keys/autounseal &> /dev/null

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault policy write autounseal /vault/unseal/autounseal.hcl &> /dev/null

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- vault token create -policy="autounseal" -wrap-ttl=12000 -format=yaml > .vault-auto-unseal-token.txt 

VAULT_AUTO_UNSEAL_TOKEN=$(grep token: .vault-auto-unseal-token.txt|awk '{print $2}'|tr -d '\r')

kubectl exec --namespace=vault-cluster --stdin --tty $TRANSIT_SERVER_NAME -- env VAULT_TOKEN=${VAULT_AUTO_UNSEAL_TOKEN} vault unwrap -format=yaml > .vault-unwrap-token.txt 

VAULT_AUTO_UNSEAL_TOKEN=$(grep client_token: .vault-unwrap-token.txt|awk '{print $2}'|tr -d '\r')


################################################################### CONFIGURE VAULT CLUSTER
echo "##########################################"
echo "info: Configuring Vault cluster..."

tee vault/cm.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  labels:
    app.kubernetes.io/name: vault
    app.kubernetes.io/creator: hossein-yousefi
    app.kubernetes.io/stack: vault-cluster
data:
  config.hcl: |
    listener "tcp" {
      tls_disable = 1
      address          = "0.0.0.0:8200"
      cluster_address  = "0.0.0.0:8201"	  
     }
    storage "consul" {
      address = "consul:8500"
      path    = "vault/"
     }
    disable_mlock = true
    seal "transit" {
      address = "http://vault-auto-unseal:8200"
      token = "${VAULT_AUTO_UNSEAL_TOKEN}"
      disable_renewal = "false"
      key_name = "autounseal"
      mount_path = "transit/"
     }
	 
---

apiVersion: v1
kind: ConfigMap
metadata:
  namespace: vault-cluster
  name: consul-client-config
  labels:
    app.kubernetes.io/name: vault
    app.kubernetes.io/creator: hossein-yousefi
    app.kubernetes.io/stack: vault-cluster
data:
  consul.json: |
   {
      "server": false,
      "datacenter": "dc1",
      "data_dir": "/consul/data/",
      "bind_addr": "0.0.0.0",
      "client_addr": "0.0.0.0",
      "retry_join": ["consul"],
      "log_level": "DEBUG",
      "acl_enforce_version_8": false
   } 
EOF

kubectl apply -f vault/cm.yaml &> /dev/null

kubectl rollout restart statefulsets --namespace=vault-cluster vault 


################################################################## Configure Vault cluster
echo "##########################################"
echo "info: initializing vault cluster..."

kubectl rollout status statefulset --namespace=vault-cluster vault

kubectl exec --namespace=vault-cluster --stdin --tty vault-0 -- vault operator init -format=yaml > vault-keys.txt

kubectl exec --namespace=vault-cluster --stdin --tty vault-0 -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -2|tail -1|sed 's/- //g') &> /dev/null
kubectl exec --namespace=vault-cluster --stdin --tty vault-0 -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -3|tail -1|sed 's/- //g') &> /dev/null
kubectl exec --namespace=vault-cluster --stdin --tty vault-0 -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -4|tail -1|sed 's/- //g') &> /dev/null

echo
echo "info: Vault cluster is ready to use."
echo "info: Please, write down the unseal keys and delete the '.vault-auto-unseal-token.txt' file"
echo "info: This is Vault transit server root token: $(grep token: .vault-auto-unseal-token.txt|awk '{print $2}'|tr -d '\r')"
echo
echo "!!ATTENTION!!  After restarting Vault transit server you should unseal it manually so, write down its keys."
echo


