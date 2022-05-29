#!/bin/bash
# Implement Vault cluster integrated with consul cluster in kubernetes.
# written by Hosein Yousefi <yousefi.hosein.o@gmail.com>

echo
echo "Deploying Consul cluster ..."
echo

kubectl apply -f consul/cm.yaml
kubectl apply -f consul/svc.yaml
kubectl apply -f consul/deploy.yaml

REPLICAS=$(kubectl get statefulsets.apps  -o custom-columns=:.spec.replicas consul|tail -1)
REPLICA=$(expr ${REPLICAS} - 1)

echo
echo "waiting for the consul's pods (it might take a few minutes)."

while [[ ! $(kubectl get po --field-selector status.phase=Running|grep consul-$REPLICA) ]]
do 
	echo -ne .
	sleep 5s
	
done

echo
echo "pod's consul are in running state."
echo
echo "Deploying vault cluster..."

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
echo
echo "initializing vault cluster..."


kubectl exec --stdin --tty vault-0 -- vault operator init -format=yaml> vault-keys.txt

echo
echo "Unsealing vault cluster..."

for i in `seq 0 $REPLICA`
do
	unseal_key_1="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -2|tail -1|sed 's/- //g')"
	unseal_key_2="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -3|tail -1|sed 's/- //g')"
	unseal_key_3="kubectl exec --stdin --tty vault-${i} -- vault operator unseal -tls-skip-verify $(grep -A 5 unseal_keys_b64 vault-keys.txt |head -4|tail -1|sed 's/- //g')"

	$unseal_key_1
	$unseal_key_2
	$unseal_key_3
done

ROOT_TOKEN=$(grep root_token vault-keys.txt |awk -F: '{print $2}'|sed 's/ //g')

echo
echo "Vault cluster is ready to use."
echo "Please, write down the unseal keys and delete the 'vault-keys.txt' file"
echo "This is your root token: ${ROOT_TOKEN}"
echo "Enjoy the rest of the day!"
echo
