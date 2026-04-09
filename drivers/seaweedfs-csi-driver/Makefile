# VERSION=latest make push
.PHONY: build container container-csi container-mount container-recycler push push-csi push-mount push-recycler clean deps

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

clean:
	go clean -r -x
	-rm -rf $(OUTPUT_DIR)
