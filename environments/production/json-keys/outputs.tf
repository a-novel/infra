output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = [for role, image in local.images : {
    source   = image.source
    producer = "a-novel/${split("/", image.path)[0]}"
    target   = "${module.runtime.repositories["production"]}/${image.path}:${image.tag}"
  }]
}
