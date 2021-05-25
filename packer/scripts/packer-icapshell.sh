#!/bin/bash
set -e
source /home/ubuntu/scripts/.env
if [ -f /home/ubuntu/scripts/update_partition_size.sh ]; then
  chmod +x /home/ubuntu/scripts/update_partition_size.sh
  /home/ubuntu/scripts/update_partition_size.sh
fi

apt-get install \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg-agent \
  software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
apt-get update
# install local docker registry
docker run -d -p 127.0.0.1:30500:5000 --restart always --name registry registry:2
docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
git clone https://github.com/k8-proxy/icap-infrastructure.git -b k8-main && cd icap-infrastructure

cd rabbitmq
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm upgrade rabbitmq --install . --namespace icap-adaptation
cd ..
cat >>openssl.cnf <<EOF
[ req ]
prompt = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
C = GB
ST = London
L = London
O = Glasswall
OU = IT
CN = icap-server
emailAddress = admin@glasswall.com
EOF
openssl req -newkey rsa:2048 -config openssl.cnf -nodes -keyout /tmp/tls.key -x509 -days 365 -out /tmp/certificate.crt
kubectl create secret tls icap-service-tls-config --namespace icap-adaptation --key /tmp/tls.key --cert /tmp/certificate.crt

# Clone ICAP SOW Version
git clone https://github.com/filetrust/icap-infrastructure.git -b main /tmp/icap-infrastructure-sow
cp /tmp/icap-infrastructure-sow/adaptation/values.yaml adaptation/
cp /tmp/icap-infrastructure-sow/administration/values.yaml administration/
cp /tmp/icap-infrastructure-sow/ncfs/values.yaml ncfs/

cd adaptation
kubectl create -n icap-adaptation secret generic policyupdateservicesecret --from-literal=username=policy-management --from-literal=password='long-password'
kubectl create -n icap-adaptation secret generic transactionqueryservicesecret --from-literal=username=query-service --from-literal=password='long-password'
kubectl create -n icap-adaptation secret generic rabbitmq-service-default-user --from-literal=username=guest --from-literal=password='guest'
if [[ "${ICAP_FLAVOUR}" == "classic" ]]; then
	snap install yq
	requestImage=$(yq eval '.imagestore.requestprocessing.tag' custom-values.yaml)
	requestRepo=$(yq eval '.imagestore.requestprocessing.repository' custom-values.yaml)
	docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
	docker pull $requestRepo:$requestImage
	docker tag $requestRepo:$requestImage localhost:30500/icap-request-processing:$requestImage
	docker push localhost:30500/icap-request-processing:$requestImage
	helm upgrade adaptation --values custom-values.yaml --install . --namespace icap-adaptation  --set imagestore.requestprocessing.registry='localhost:30500/' \
	--set imagestore.requestprocessing.repository='icap-request-processing'
fi

if [[ "${ICAP_FLAVOUR}" == "golang" ]]; then
	helm upgrade adaptation --values custom-values.yaml --install . --namespace icap-adaptation
	# Install minio
	kubectl create ns minio
	helm repo add minio https://helm.min.io/
	helm install -n minio --set accessKey=minio,secretKey=$MINIO_SECRET,buckets[0].name=sourcefiles,buckets[0].policy=none,buckets[0].purge=false,buckets[1].name=cleanfiles,buckets[1].policy=none,buckets[1].purge=false,fullnameOverride=minio-server,persistence.enabled=false minio/minio --generate-name
	kubectl create -n icap-adaptation secret generic minio-credentials --from-literal=username='minio' --from-literal=password=$MINIO_SECRET
	git clone https://github.com/k8-proxy/go-k8s-infra.git -b develop && cd go-k8s-infra
	kubectl -n icap-adaptation scale --replicas=0 deployment/adaptation-service
	pushd services
	helm upgrade servicesv2 --install . --namespace icap-adaptation
	popd
fi


kubectl patch svc frontend-icap-lb -n icap-adaptation --type='json' -p '[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/0/nodePort","value":1344},{"op":"replace","path":"/spec/ports/1/nodePort","value":1345}]'
cd ..

if [[ "${INSTALL_M_UI}" == "true" ]]; then
  mkdir -p /var/local/rancher/host/c/userstore
  cp -r default-user/* /var/local/rancher/host/c/userstore/
  kubectl create ns management-ui
  kubectl create ns icap-ncfs
  cd ncfs
  kubectl create -n icap-ncfs secret generic ncfspolicyupdateservicesecret --from-literal=username=policy-update --from-literal=password='long-password'
  helm upgrade ncfs --values custom-values.yaml --install . --namespace icap-ncfs
  cd ..
  kubectl create -n management-ui secret generic transactionqueryserviceref --from-literal=username=query-service --from-literal=password='long-password'
  kubectl create -n management-ui secret generic policyupdateserviceref --from-literal=username=policy-management --from-literal=password='long-password'
  kubectl create -n management-ui secret generic ncfspolicyupdateserviceref --from-literal=username=policy-update --from-literal=password='long-password'
  cd administration
  sed -i 's|traefik|nginx|' templates/management-ui/ingress.yml
  helm upgrade administration --values custom-values.yaml --install . --namespace management-ui
  cd ..
  kubectl delete secret/smtpsecret -n management-ui
  kubectl create -n management-ui secret generic smtpsecret \
    --from-literal=SmtpHost=$SMTPHOST \
    --from-literal=SmtpPort=$SMTPPORT \
    --from-literal=SmtpUser=$SMTPUSER \
    --from-literal=SmtpPass=$SMTPPASS \
    --from-literal=TokenSecret='12345678901234567890123456789012' \
    --from-literal=TokenLifetime='00:01:00' \
    --from-literal=EncryptionSecret='12345678901234567890123456789012' \
    --from-literal=ManagementUIEndpoint='http://management-ui:8080' \
    --from-literal=SmtpSecureSocketOptions='http://management-ui:8080'

fi

# Install Filedrop UI
if [[ "${INSTALL_FILEDROP_UI}" == "true" ]]; then
  INSTALL_CSAPI="true"
  git clone https://github.com/k8-proxy/k8-rebuild.git && pushd k8-rebuild
	# build images
	ui_tag=$(yq eval '.sow-rest-ui.image.tag' kubernetes/values.yaml)
	ui_registry=$(yq eval '.sow-rest-ui.image.registry' kubernetes/values.yaml)
	ui_repo=$(yq eval '.sow-rest-ui.image.repository' kubernetes/values.yaml)
	docker pull $ui_registry/$ui_repo:$ui_tag
	docker tag $ui_registry/$ui_repo:$ui_tag localhost:30500/k8-rebuild-file-drop:$ui_tag
	docker push localhost:30500/k8-rebuild-file-drop:$ui_tag
	rm -rf kubernetes/charts/sow-rest-api-0.1.0.tgz
  cat >kubernetes/templates/ingress.yaml <<EOF
{{ if (eq .Values.nginx.service.type "ClusterIP") }}
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: k8-rebuild
spec:
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: sow-rest-api
            port: 
              number: 80
      - path: /swagger
        pathType: Prefix
        backend:
          service:
            name: sow-rest-api
            port:
              number: 80
      - path: /Swg
        pathType: Prefix
        backend:
          service:
            name: sow-rest-api
            port:
              number: 80
      - path: /openapi.json
        pathType: Prefix
        backend:
          service:
            name: sow-rest-api
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          name: "sow-rest-ui"
          servicePort: 80
{{- end -}}

EOF
	sed -i 's/sow-rest-api/proxy-rest-api.icap-adaptation.svc.cluster.local:8080/g' kubernetes/values.yaml
	# install helm charts
	helm upgrade --install k8-rebuild --set nginx.service.type=ClusterIP \
	--set sow-rest-ui.image.registry=localhost:30500 \
	--atomic kubernetes/
fi
# Install CS-API
if [[ "${INSTALL_CSAPI}" == "true" ]]; then
  wget https://raw.githubusercontent.com/k8-proxy/cs-k8s-api/main/deployment.yaml
  docker pull $CS_API_IMAGE
  CS_IMAGE_VERSION=$(echo $CS_API_IMAGE | cut -d":" -f2)
  docker tag $CS_API_IMAGE localhost:30500/cs-k8s-api:$CS_IMAGE_VERSION
  docker push localhost:30500/cs-k8s-api:$CS_IMAGE_VERSION
  sed -i 's|glasswallsolutions/cs-k8s-api:.*|localhost:30500/cs-k8s-api:'$CS_IMAGE_VERSION'|' deployment.yaml
  kubectl apply -f deployment.yaml -n icap-adaptation
  kubectl patch svc proxy-rest-api -n icap-adaptation --type='json' -p '[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/0/nodePort","value":8080}]'
fi
docker logout
# defining vars
DEBIAN_FRONTEND=noninteractive
KERNEL_BOOT_LINE='net.ifnames=0 biosdevname=0'

# install needed packages
apt install -y telnet tcpdump open-vm-tools net-tools dialog curl git sed grep fail2ban
systemctl enable fail2ban.service
tee -a /etc/fail2ban/jail.d/sshd.conf <<EOF >/dev/null
[sshd]
enabled = true
port = ssh
action = iptables-multiport
logpath = /var/log/auth.log
bantime  = 10h
findtime = 10m
maxretry = 5
EOF
systemctl restart fail2ban

if [[ "$CREATE_OVA" == "true" ]]; then
  # switching to predictable network interfaces naming
  grep "$KERNEL_BOOT_LINE" /etc/default/grub >/dev/null || sed -Ei "s/GRUB_CMDLINE_LINUX=\"(.*)\"/GRUB_CMDLINE_LINUX=\"\1 $KERNEL_BOOT_LINE\"/g" /etc/default/grub

  # remove swap
  swapoff -a && rm -f /swap.img && sed -i '/swap.img/d' /etc/fstab && echo Swap removed

  # update grub
  update-grub
  curl -sSL https://raw.githubusercontent.com/vmware/cloud-init-vmware-guestinfo/master/install.sh | sh -
  # installing the wizard
  install -T /home/ubuntu/scripts/cwizard.sh /usr/local/bin/wizard -m 0755

  # installing initconfig ( for running wizard on reboot )
  cp -f /home/ubuntu/scripts/initconfig.service /etc/systemd/system/initconfigwizard.service
  install -T /home/ubuntu/scripts/initconfig.sh /usr/local/bin/initconfig.sh -m 0755
  systemctl daemon-reload

  # enable initconfig for the next reboot
  systemctl enable initconfigwizard

fi
