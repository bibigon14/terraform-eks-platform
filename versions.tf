terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Bucket and table below are created once, manually, via docs/bootstrap.md
  # (classic chicken-and-egg problem: you can't store state in a bucket
  # that Terraform itself hasn't created yet).
  backend "s3" {
    bucket         = "REPLACE_ME-tfstate"
    key            = "terraform-eks-platform/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "REPLACE_ME-tfstate-lock"
    encrypt        = true
  }
}
