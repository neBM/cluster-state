terraform {
  backend "pg" {}
}

module "dummy" {
  source = "./modules/dummy"
}

module "media-centre" {
  source = "./modules/media-centre"
}

module "plextraktsync" {
  source = "./modules/plextraktsync"
}

module "matrix" {
  source = "./modules/matrix"
}

module "elk" {
  source = "./modules/elk"
}

module "renovate" {
  source = "./modules/renovate"
}

module "plugin-csi" {
  source = "./modules/plugin-csi"
}

module "home-assistant" {
  source = "./modules/home-assistant"
}

module "forgejo" {
  source = "./modules/forgejo"
}

module "keycloak" {
  source = "./modules/keycloak"
}
