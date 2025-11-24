ARG BASEIMAGE

FROM quay.io/kairos/kairos-init:v0.5.28 AS kairos-init

FROM ${BASEIMAGE}

ARG KUBERNETES_DISTRO
ARG KUBERNETES_VERSION
ARG VERSION

RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init /kairos-init --version "${VERSION}" -m rpi4 -k "${KUBERNETES_DISTRO}" --k8sversion "${KUBERNETES_VERSION}"


# RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
#     if [ -n "${KUBERNETES_DISTRO}" ]; then \
#     K8S_FLAG="-p ${KUBERNETES_DISTRO}"; \
#     if [ "${KUBERNETES_DISTRO}" = "k0s" ] && [ -n "${KUBERNETES_VERSION}" ]; then \
#     K8S_VERSION_FLAG="--provider-k0s-version ${KUBERNETES_VERSION}"; \
#     elif [ "${KUBERNETES_DISTRO}" = "k3s" ] && [ -n "${KUBERNETES_VERSION}" ]; then \
#     K8S_VERSION_FLAG="--provider-k3s-version ${KUBERNETES_VERSION}"; \
#     else \
#     K8S_VERSION_FLAG=""; \
#     fi; \
#     else \
#     K8S_FLAG=""; \
#     K8S_VERSION_FLAG=""; \
#     fi; \
#     /kairos-init --version "${VERSION}" -m rpi4 ${K8S_FLAG} ${K8S_VERSION_FLAG} 
#
#


