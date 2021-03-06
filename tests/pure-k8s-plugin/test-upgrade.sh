#!/usr/bin/env bash

# Copyright 2017, Pure Storage Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -xe

# This script is to test the upgrade from the latest GA version to the current developing one 
script_abs_path=`cd $(dirname $0); echo $(pwd)/$(basename $0)`
WORKSPACE=$(dirname ${script_abs_path})/../..

TEST_CHART_NAME=pure-k8s-plugin

CHARTS_DIR=${WORKSPACE}
CHARTS_TESTS_DIR=${WORKSPACE}/tests

MINIKUBE_VM_DRIVER=${MINIKUBE_VM_DRIVER:-virtualbox}
MINIKUBE_INSTANCE_NAME=${TEST_CHART_NAME}

CHECK_LIMIT=30
CHECK_INTERVAL=10

function verify_chart_installation {
    # verify for pure-provisioner
    local imageInstalled=$(kubectl get deploy pure-provisioner -o json | jq -r '.spec.template.spec.containers[].image')
    [ "${imageInstalled}" == "purestorage/k8s:${IMAGE_TAG}" ]

    local desiredProvisioner=1
    local n=0
    while true; do
        [ $n -lt ${CHECK_LIMIT} ]
        n=$[$n+1]
        sleep ${CHECK_INTERVAL}
        local readyProvisioner=$(kubectl get deploy pure-provisioner -o json | jq -r '.status.readyReplicas')
        [ "${readyProvisioner}" == "${desiredProvisioner}" ] && break
    done

    # verify for pure-flex
    local imageInstalled=$(kubectl get ds pure-flex -o json | jq -r '.spec.template.spec.containers[].image')
    [ "${imageInstalled}" == "purestorage/k8s:${IMAGE_TAG}" ]

    local desiredFlexes=$(kubectl get ds pure-flex -o json | jq -r '.status.desiredNumberScheduled')
    n=0
    while true; do
        [ $n -lt ${CHECK_LIMIT} ]
        n=$[$n+1]
        sleep ${CHECK_INTERVAL}
        local readyFlexes=$(kubectl get ds pure-flex -o json | jq -r '.status.numberReady')
        [ "${readyFlexes}" == "${desiredFlexes}" ] && break
    done
}

export KUBECONFIG=${CHARTS_TESTS_DIR}/${TEST_CHART_NAME}/kube.conf
export HELM_HOME=${CHARTS_TESTS_DIR}/${TEST_CHART_NAME}/helm

source ${CHARTS_TESTS_DIR}/common/minikube-utils.sh

function final_steps() {
    if [ -e ${CHARTS_DIR}/${TEST_CHART_NAME}/Chart.yaml.bak ]; then
        mv ${CHARTS_DIR}/${TEST_CHART_NAME}/Chart.yaml.bak ${CHARTS_DIR}/${TEST_CHART_NAME}/Chart.yaml
    fi
    cleanup_minikube ${MINIKUBE_INSTANCE_NAME}
    rm -rf ${KUBECONFIG} ${HELM_HOME}
}
trap final_steps EXIT

start_minikube ${MINIKUBE_INSTANCE_NAME} ${MINIKUBE_VM_DRIVER}

TEST_CHARTS_REPO_URL=${TEST_CHARTS_REPO_URL:-https://purestorage.github.io/helm-charts}
TEST_CHARTS_REPO_NAME=pure

TILLER_NAMESPACE=kube-system
source ${CHARTS_TESTS_DIR}/common/helm-utils.sh
init_helm ${TEST_CHARTS_REPO_URL} ${TEST_CHARTS_REPO_NAME}

CHART_VERSION_LIST=$(helm search ${TEST_CHARTS_REPO_NAME}/${TEST_CHART_NAME} -l | grep ${TEST_CHART_NAME} | awk '{print $2}')
LATEST_CHART_VERSION=$(helm search ${TEST_CHARTS_REPO_NAME}/${TEST_CHART_NAME} | grep ${TEST_CHART_NAME} | awk '{print $2}')
IMAGE_TAG=${TEST_CHART_GA_VERSION:-latest}
isValidVersion=0
if [ "${IMAGE_TAG}" == "latest" ]; then
    IMAGE_TAG=${LATEST_CHART_VERSION}
else
    for v in ${CHART_VERSION_LIST}; do
        if [ "$v" == ${IMAGE_TAG} ]; then
            isValidVersion=1
            break
        fi
    done
    if [ $isValidVersion -ne 1 ]; then
        echo "Failure: Invalid chart version ${IMAGE_TAG}"
        false
    fi
fi

echo "Installing the helm chart of ${TEST_CHART_NAME} ..."
TEST_CHART_INSTANCE=pure
# for testing upgrade only, set arrays to empty
helm install -n ${TEST_CHART_INSTANCE} ${TEST_CHARTS_REPO_NAME}/${TEST_CHART_NAME} --version ${IMAGE_TAG} --set arrays=""

echo "Verifying the installation ..."
verify_chart_installation
kubectl get all -o wide

echo "Upgrading the helm chart of ${TEST_CHART_NAME} ..."
CHART_DEV_VERSION=$(sh ${CHARTS_TESTS_DIR}/common/generate-version.sh)
sed -i.bak "s/version: [0-9.]*/version: ${CHART_DEV_VERSION}/" ${CHARTS_DIR}/${TEST_CHART_NAME}/Chart.yaml
IMAGE_TAG=$(grep ' tag:' ${CHARTS_DIR}/${TEST_CHART_NAME}/values.yaml | cut -d':' -f2 | tr -d ' ')
helm upgrade ${TEST_CHART_INSTANCE} ${CHARTS_DIR}/${TEST_CHART_NAME} --version ${CHART_DEV_VERSION} --set arrays=""

echo "Verifying the upgrade ..."
verify_chart_installation
kubectl get all -o wide

helm history ${TEST_CHART_INSTANCE}
