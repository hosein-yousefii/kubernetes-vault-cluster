#!/bin/bash
# Implement Vault cluster integrated with consul cluster in kubernetes.
# written by Hosein Yousefi <yousefi.hosein.o@gmail.com>

################################################################## CONSUL CLUSTER
echo
echo "Deploying Consul cluster ..."
echo

kubectl apply -f consul/cm.yaml
kubectl apply -f consul/svc.yaml
kubectl apply -f consul/deploy.yaml

REPLICAS=$(kubectl get statefulsets.apps  -o custom-columns=:.spec.replicas consul|tail -1)
REPLICA=$(expr ${REPLICAS} - 1)

echo
echo "waiting for the Consul's pods (it might take a few minutes)."

while [[ ! $(kubectl get po --field-selector status.phase=Running|grep consul-$REPLICA) ]]
do 
	echo -ne .
	sleep 5s
	
done

echo
echo "Consul cluster are in running state."

################################################################## VAULT TRANSIT FOR AUTO UNSEALING
echo
echo "Deploying Vault transit server ..."
echo

kubectl apply -f auto-unseal/pvc.yaml
kubectl apply -f auto-unseal/cm.yaml
kubectl apply -f auto-unseal/svc.yaml
kubectl apply -f auto-unseal/deploy.yaml

echo
echo "waiting for the Vault transit (auto-unseal) pod (it might take a few minutes)."

while [[ ! $(kubectl get po --field-selector status.phase=Running|grep vault-auto-unseal) ]]
do
	echo -ne .
	sleep 2s
	
done

echo "Vault transit server successfuly deployed."
echo

################################################################## VAULT CLUSTER
echo
echo "Deploying Vault cluster..."

kubectl apply -f vault/cm.yaml
kubectl apply -f vault/svc.yaml
kubectl apply -f vault/deploy.yaml

REPLICAS=$(kubectl get statefulsets.apps  -o custom-columns=:.spec.replicas vault|tail -1)
REPLICA=$(expr ${REPLICAS} - 1)

echo
echo "waiting for the vault's pods (it might take a few minutes)."

while [[ ! $(kubectl get po --field-selector status.phase=Running|grep vault-$REPLICA) ]]
do 
	echo -ne .
	sleep 5s
	
done

echo
echo "pod's vault are in running state."


################################################################## CONFIGURE VAULT TRANSIT SERVER
echo
echo "initializing Vault transit server..."

REPLICASET_TRANSIT_SERVER_NAME=$(kubectl get deployments.apps vault-auto-unseal -o custom-columns=:.status.conditions[1].message|awk '{print $2}'|sed 's/"//g')
TRANSIT_SERVER_NAME=$(kubectl describe replicasets.apps $REPLICASET_TRANSIT_SERVER_NAME |tail -1|awk '{print $7}')

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault operator init -format=yaml > vault-auto-unseal-keys.txt

echo
echo "Unsealing Vault transit server..."

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -2|tail -1|sed 's/- //g')
kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -3|tail -1|sed 's/- //g')
kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-auto-unseal-keys.txt |head -4|tail -1|sed 's/- //g')

VAULT_AUTO_UNSEAL_ROOT_TOKEN=$(grep root_token vault-auto-unseal-keys.txt |awk -F: '{print $2}'|sed 's/ //g')

sleep 3s

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault login -tls-skip-verify ${VAULT_AUTO_UNSEAL_ROOT_TOKEN}

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault secrets enable transit

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault write -f transit/keys/autounseal

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault policy write autounseal /vault/unseal/autounseal.hcl

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- vault token create -policy="autounseal" -wrap-ttl=12000 -format=yaml > .vault-auto-unseal-token.txt

VAULT_AUTO_UNSEAL_TOKEN=$(grep token: .vault-auto-unseal-token.txt|awk '{print $2}'|tr -d '\r')

kubectl exec --stdin --tty $TRANSIT_SERVER_NAME -- env VAULT_TOKEN=${VAULT_AUTO_UNSEAL_TOKEN} vault unwrap



################################################################## CONFIGURE VAULT CLUSTER
echo
echo "Configuring Vault cluster..."

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
      key_name = "auto-unseal"
      mount_path = "transit/"
     }

EOF

kubectl apply -f vault/cm.yaml

kubectl rollout restart statefulsets vault



##################################################################
echo
echo "initializing vault cluster..."

#############
while [[ ! $(kubectl get po --field-selector status.phase=Running|grep vault-0) ]]
do 
	echo -ne .
	sleep 5s
	
done

kubectl exec --stdin --tty vault-0 -- vault operator init -format=yaml > vault-keys.txt

ROOT_TOKEN=$(grep root_token vault-keys.txt |awk -F: '{print $2}'|sed 's/ //g')



for i in `seq 0 $REPLICA`
do
	unseal_key_1="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -2|tail -1|sed 's/- //g')"
	unseal_key_2="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -3|tail -1|sed 's/- //g')"
	unseal_key_3="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -4|tail -1|sed 's/- //g')"

	$unseal_key_1
	$unseal_key_2
	$unseal_key_3
done


echo
echo "Vault transit server is ready to use."
echo "Please, write down the unseal keys and delete the 'vault-auto-unseal-keys.txt' file"
echo "This is Vault transit server root token: ${ROOT_TOKEN}"