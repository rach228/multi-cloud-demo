TMP_REPO=/tmp/hybrid-coolstore

BASE:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

include $(BASE)/config.sh

.PHONY: install remote-install clean-remote-install create-aws-credentials install-gitops deploy-gitea create-clusters demo-manual-install argocd argocd-password gitea coolstore-ui topology-view coolstore-a-password metrics alerts generate-orders email remove-lag login-a login-b login-c contexts hugepages f5 verify-f5 installer-image create-bastion-credentials install-with-f5 create-argocd-account create-token deploy-handler add-gitea-webhook

install-app: install-gitops deploy-gitea create-cluster-dependencies create-argocd-account create-token deploy-handler add-gitea-webhook
	@echo "done"

config.sh
	oc apply -f $(BASE)/yaml/remote-installer/remote-installer.yaml
	@/bin/echo -n "waiting for job to appear..."
	@until oc get -n $(REMOTE_INSTALL_PROJ) job/remote-installer 2>/dev/null >/dev/null; do \
	  /bin/echo -n "."; \
	  sleep 10; \
	done
	@echo "done"
	oc wait -n $(REMOTE_INSTALL_PROJ) --for condition=ready po -l job-name=remote-installer
	oc logs -n $(REMOTE_INSTALL_PROJ) -f job/remote-installer

install-gitops:
	$(BASE)/scripts/install-gitops

deploy-gitea:
	$(BASE)/scripts/clean-gitea
	$(BASE)/scripts/deploy-gitea
	$(BASE)/scripts/clone-from-template $(BASE)/yaml $(TMP_REPO)
	$(BASE)/scripts/init-gitea $(GIT_PROJ) gitea $(GIT_ADMIN) $(GIT_PASSWORD) $(GIT_ADMIN)@example.com $(TMP_REPO) $(GIT_REPO) 'Demo App'
	rm -rf $(TMP_REPO)

create-cluster-dependencies:
	@if ! oc get project open-cluster-management 2>/dev/null >/dev/null; then \
	  echo "this cluster does not have ACM installed"; \
	  oc apply -f $(BASE)/yaml/single-cluster-rbac/clusterrolebinding.yaml; \
	  oc apply -f $(BASE)/yaml/single-cluster/coolstore.yaml; \
	else \
	  echo "this cluster has ACM installed"; \
	  oc apply -f $(BASE)/yaml/acm-gitops/acm-gitops.yaml; \
	  $(BASE)/scripts/configure-hugepages; \
	  oc apply -f $(BASE)/yaml/argocd/coolstore.yaml; \
	fi
	@# Note we are performing some tasks between cluster provisioning and
	@# installing Submariner in order to give the cluster some time to settle


create-argocd-account:
	oc patch argocd/openshift-gitops \
	  -n openshift-gitops \
	  --type merge \
	  -p '{"spec":{"extraConfig":{"accounts.$(ARGO_ACCOUNT)":"login, apiKey"}}}'

	oc get -n openshift-gitops argocd/openshift-gitops -o jsonpath='{.spec.rbac.policy}' \
	| \
	tee /tmp/policy.csv

	echo 'p, $(ARGO_ACCOUNT), applications, sync, default/*, allow' \
	>> \
	/tmp/policy.csv

	cat /tmp/policy.csv | sed 's/$$/\\n/' | tr -d '\n' | sed 's/\\n$$//' > /tmp/policy2.csv

	oc patch argocd/openshift-gitops \
	  -n openshift-gitops \
	  -p '{"spec":{"rbac":{"policy":"'"`cat /tmp/policy2.csv`"'"}}}' \
	  --type merge

	rm -f /tmp/policy.csv /tmp/policy2.csv
	sleep 5


create-token:
	@ARGOHOST="`oc get -n openshift-gitops route/openshift-gitops-server -o jsonpath='{.spec.host}'`"; \
	if [ -z "$$ARGOHOST" ]; then echo "could not retrieve argocd host"; exit 1; fi; \
	echo "argocd host is $$ARGOHOST"; \
	/bin/echo -n "waiting for API to be available..."; \
	while [ -z "`curl -sk https://$$ARGOHOST/api/version 2>/dev/null | jq -r '.Version'`" ]; do \
	  /bin/echo -n "."; \
	  sleep 5; \
	done; \
	echo "done"; \
	PASSWORD="`oc get -n openshift-gitops secret/openshift-gitops-cluster -o jsonpath='{.data.admin\.password}' | base64 -d`"; \
	if [ -z "$$PASSWORD" ]; then echo "could not retrieve argocd admin password"; exit 1; fi; \
	echo "argocd admin password is $$PASSWORD"; \
	JWT=`curl -sk -XPOST -H 'Accept: application/json' -H 'Content-type: application/json' --data '{"username":"admin","password":"'"$$PASSWORD"'"}' "https://$$ARGOHOST/api/v1/session" | jq -r '.token'`; \
	if [ -z "$$JWT" ]; then echo "could not retrieve argocd JWT"; exit 1; fi; \
	echo "argocd JWT is $$JWT"; \
	TOKEN=`curl -sk -XPOST -H 'Accept: application/json' -H 'Content-type: application/json' -H "Authorization: Bearer $$JWT" --data '{"id":"$(TOKEN_ID)","name":"'"$(ARGO_ACCOUNT)"'"}' "https://$$ARGOHOST/api/v1/account/$(ARGO_ACCOUNT)/token" | jq -r '.token'`; \
	if [ -z "$$TOKEN" ]; then echo "could not generate token"; exit 1; fi; \
	echo "token is $$TOKEN"; \
	/bin/echo -n "$$TOKEN" > $(TOKEN_FILE)


deploy-handler:
	# this section is not used because of a bug in the ArgoCD certificate
	# - the incorrect service name is used
	#rm -rf /tmp/certs
	#mkdir -p /tmp/certs
	#oc extract -n openshift-gitops secret/argocd-secret --keys=tls.crt --to=/tmp/certs
	#oc create -n $(HANDLER_PROJ) secret generic argocd-sync-certs --from-file=argocd.crt=/tmp/certs/tls.crt
	#oc label -n $(HANDLER_PROJ) secret/argocd-sync-certs app=argocd-sync
	#rm -rf /tmp/certs

	oc create -n $(HANDLER_PROJ) secret generic argocd-sync \
	  --from-file=TOKEN=$(TOKEN_FILE) \
	  --from-literal=APP=$(ARGO_APP) \
	  --from-literal=IGNORECERT=true

	oc label -n $(HANDLER_PROJ) secret/argocd-sync app=argocd-sync

	oc apply -n $(HANDLER_PROJ) -f $(BASE)/yaml/argocd-sync.yaml


add-gitea-webhook:
	@/bin/echo -n "waiting for handler to come up..."
	@HANDLER_HOST="`oc get -n $(HANDLER_PROJ) route/argocd-sync -o jsonpath='{.spec.host}'`"; \
	if [ -z "$$HANDLER_HOST" ]; then \
	  echo "could not get handler host"; \
	  exit 1; \
	fi; \
	while [ "`curl -s http://$$HANDLER_HOST/healthz 2>/dev/null`" != "OK" ]; do \
	  /bin/echo -n "."; \
	  sleep 5; \
	done
	@echo "done"

	$(BASE)/scripts/gitea-webhook \
	  $(GIT_PROJ) \
	  gitea \
	  $(GIT_ADMIN) \
	  $(GIT_PASSWORD) \
	  $(GIT_REPO) \
	  http://argocd-sync.$(HANDLER_PROJ).svc:8080 \
	  push \
	  main

