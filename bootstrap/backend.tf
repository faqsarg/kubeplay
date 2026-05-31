terraform {
  backend "s3" {
    bucket         = "faqsarg-test-tfstate-bucket"
    key            = "bootstrap/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks"
  }
}
