# SeaweedFS server image built from the neBM fork.
# Sideload ONLY — the registry is backed by SeaweedFS itself, so pushing
# this image into registry.brmartin.co.uk would be a chicken-and-egg dep.
# See memory/feedback_always_sideload_seaweedfs_images.md.

REGISTRY_NAME ?= chrislusf
IMAGE_NAME    ?= seaweedfs
# Tag scheme: <upstream base tag>-nebm-<short fork commit>. Unique enough
# that k3s will not try to pull from docker hub when IfNotPresent.
SEAWEEDFS_COMMIT ?= d4cb0322979c80e9ba4fe614db118f5bb70aaee1
BASE_TAG         ?= 4.18
SHORT_COMMIT     := $(shell echo $(SEAWEEDFS_COMMIT) | cut -c1-8)
VERSION          ?= $(BASE_TAG)-nebm-$(SHORT_COMMIT)
IMAGE_TAG        := $(REGISTRY_NAME)/$(IMAGE_NAME):$(VERSION)

OUTPUT_DIR := _output
AMD64_TAR  := $(OUTPUT_DIR)/seaweedfs-$(VERSION)-amd64.tar
ARM64_TAR  := $(OUTPUT_DIR)/seaweedfs-$(VERSION)-arm64.tar

AMD64_NODES ?= hestia.lan
ARM64_NODES ?= heracles.lan nyx.lan

.PHONY: tars build-amd64 build-arm64 sideload sideload-amd64 sideload-arm64 verify clean

$(OUTPUT_DIR):
	mkdir -p $@

tars: $(AMD64_TAR) $(ARM64_TAR)

$(AMD64_TAR): Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/amd64 \
	  --build-arg SEAWEEDFS_COMMIT=$(SEAWEEDFS_COMMIT) \
	  -t $(IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f Dockerfile .

$(ARM64_TAR): Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/arm64 \
	  --build-arg SEAWEEDFS_COMMIT=$(SEAWEEDFS_COMMIT) \
	  -t $(IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f Dockerfile .

build-amd64: $(AMD64_TAR)
build-arm64: $(ARM64_TAR)

sideload: sideload-amd64 sideload-arm64

sideload-amd64: $(AMD64_TAR)
	@for node in $(AMD64_NODES); do \
	  echo ">>> sideloading $(IMAGE_TAG) -> $$node (amd64)"; \
	  scp $(AMD64_TAR) $$node:/tmp/seaweedfs-server.tar; \
	  ssh $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-server.tar && rm /tmp/seaweedfs-server.tar"; \
	done

sideload-arm64: $(ARM64_TAR)
	@for node in $(ARM64_NODES); do \
	  echo ">>> sideloading $(IMAGE_TAG) -> $$node (arm64)"; \
	  scp $(ARM64_TAR) $$node:/tmp/seaweedfs-server.tar; \
	  ssh $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-server.tar && rm /tmp/seaweedfs-server.tar"; \
	done

verify:
	@for node in $(AMD64_NODES) $(ARM64_NODES); do \
	  echo ">>> $$node:"; \
	  ssh $$node "sudo k3s ctr -n k8s.io images ls | grep $(VERSION) || echo '  MISSING'"; \
	done

clean:
	rm -rf $(OUTPUT_DIR)
