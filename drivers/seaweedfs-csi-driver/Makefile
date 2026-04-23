# Build:   VERSION=v0.1.12 make container-csi
# Sideload: VERSION=v0.1.12 make sideload-csi
#
# Sideload ONLY — the in-cluster registry is backed by SeaweedFS itself,
# so pushing would be a chicken-and-egg dep. See
# memory/feedback_always_sideload_seaweedfs_images.md.
.PHONY: build container container-csi container-mount container-recycler \
        push push-csi push-mount push-recycler \
        tars-csi sideload-csi sideload-csi-amd64 sideload-csi-arm64 \
        clean deps

REGISTRY_NAME ?= chrislusf
DRIVER_IMAGE_NAME ?= seaweedfs-csi-driver
MOUNT_IMAGE_NAME ?= seaweedfs-mount
RECYCLER_IMAGE_NAME ?= seaweedfs-consumer-recycler
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD)
LDFLAGS ?= -s -w -X github.com/seaweedfs/seaweedfs-csi-driver/pkg/driver.gitCommit=${COMMIT}

OUTPUT_DIR := _output
DRIVER_BINARY := $(OUTPUT_DIR)/seaweedfs-csi-driver
MOUNT_BINARY := $(OUTPUT_DIR)/seaweedfs-mount
RECYCLER_BINARY := $(OUTPUT_DIR)/seaweedfs-consumer-recycler

DRIVER_IMAGE_TAG := $(REGISTRY_NAME)/$(DRIVER_IMAGE_NAME):$(VERSION)
MOUNT_IMAGE_TAG := $(REGISTRY_NAME)/$(MOUNT_IMAGE_NAME):$(VERSION)
RECYCLER_IMAGE_TAG := $(REGISTRY_NAME)/$(RECYCLER_IMAGE_NAME):$(VERSION)

# Tars for sideloading the csi-driver image to k3s nodes.
DRIVER_AMD64_TAR := $(OUTPUT_DIR)/$(DRIVER_IMAGE_NAME)-$(VERSION)-amd64.tar
DRIVER_ARM64_TAR := $(OUTPUT_DIR)/$(DRIVER_IMAGE_NAME)-$(VERSION)-arm64.tar

AMD64_NODES ?= hestia.lan
ARM64_NODES ?= heracles.lan nyx.lan

deps:
	go mod tidy

build: $(DRIVER_BINARY) $(MOUNT_BINARY) $(RECYCLER_BINARY)

$(OUTPUT_DIR):
	mkdir -p $@

$(DRIVER_BINARY): | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-csi-driver/main.go

$(MOUNT_BINARY): | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-mount/main.go

$(RECYCLER_BINARY): | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-consumer-recycler/

container: container-csi container-mount container-recycler

container-csi: $(DRIVER_BINARY)
	docker build -t $(DRIVER_IMAGE_TAG) -f cmd/seaweedfs-csi-driver/Dockerfile.dev .

container-mount: $(MOUNT_BINARY)
	docker build -t $(MOUNT_IMAGE_TAG) -f cmd/seaweedfs-mount/Dockerfile.dev .

container-recycler:
	docker build -t $(RECYCLER_IMAGE_TAG) -f cmd/seaweedfs-consumer-recycler/Dockerfile .

push: push-csi push-mount push-recycler

push-csi: container-csi
	docker push $(DRIVER_IMAGE_TAG)

push-mount: container-mount
	docker push $(MOUNT_IMAGE_TAG)

push-recycler: container-recycler
	docker push $(RECYCLER_IMAGE_TAG)

tars-csi: $(DRIVER_AMD64_TAR) $(DRIVER_ARM64_TAR)

$(DRIVER_AMD64_TAR): cmd/seaweedfs-csi-driver/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/amd64 \
	  -t $(DRIVER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-csi-driver/Dockerfile .

$(DRIVER_ARM64_TAR): cmd/seaweedfs-csi-driver/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/arm64 \
	  -t $(DRIVER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-csi-driver/Dockerfile .

sideload-csi: sideload-csi-amd64 sideload-csi-arm64

sideload-csi-amd64: $(DRIVER_AMD64_TAR)
	@for node in $(AMD64_NODES); do \
	  echo ">>> sideloading $(DRIVER_IMAGE_TAG) -> $$node (amd64)"; \
	  scp $(DRIVER_AMD64_TAR) $$node:/tmp/seaweedfs-csi-driver.tar; \
	  ssh $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-csi-driver.tar && rm /tmp/seaweedfs-csi-driver.tar"; \
	done

sideload-csi-arm64: $(DRIVER_ARM64_TAR)
	@for node in $(ARM64_NODES); do \
	  echo ">>> sideloading $(DRIVER_IMAGE_TAG) -> $$node (arm64)"; \
	  scp $(DRIVER_ARM64_TAR) $$node:/tmp/seaweedfs-csi-driver.tar; \
	  ssh $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-csi-driver.tar && rm /tmp/seaweedfs-csi-driver.tar"; \
	done

clean:
	go clean -r -x
	-rm -rf $(OUTPUT_DIR)
