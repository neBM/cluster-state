terraform {
  backend "pg" {}
}

module "dummy" {
  source = "./modules/dummy"
}
