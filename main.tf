terraform {
  backend "pg" {}
}

module "dummy" {
  source = "./modules/dummy"
}

module "media-centre" {
  source = "./modules/media-centre"
}

module "code-server" {
  source = "./modules/code-server"
}
