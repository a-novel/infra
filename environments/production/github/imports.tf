# The GitHub root adopts what `a-novel repo update` built (a-novel/.github#534): the rulesets,
# environments and scoped secret access. Once applied, these blocks and the adopt variable go. The IDs
# are GitHub's, read from the live repositories.
locals {
  adopted_rulesets = var.adopt ? {
    "a-novel" = {
      ".github:commit-messages"                   = 24847873
      ".github:master"                            = 12016486
      ".github:release-lines"                     = 24853920
      ".github:require-approval"                  = 12016497
      ".github:tags"                              = 18274085
      "infra:commit-messages"                     = 24849220
      "infra:master"                              = 21253472
      "infra:require-approval"                    = 21253473
      "platform-studio:commit-messages"           = 24849258
      "platform-studio:master"                    = 20990697
      "platform-studio:release-lines"             = 24853961
      "platform-studio:require-approval"          = 20990698
      "platform-studio:tags"                      = 20990699
      "platform-template:commit-messages"         = 24849244
      "platform-template:master"                  = 19658617
      "platform-template:release-lines"           = 24853952
      "platform-template:require-approval"        = 19658620
      "platform-template:tags"                    = 19658621
      "service-authentication:commit-messages"    = 24847990
      "service-authentication:master"             = 5561015
      "service-authentication:release-lines"      = 24853987
      "service-authentication:require-approval"   = 7150510
      "service-authentication:retired-lines"      = 26089010
      "service-authentication:tags"               = 18233587
      "service-genai:commit-messages"             = 24849307
      "service-genai:master"                      = 19786361
      "service-genai:release-lines"               = 24854004
      "service-genai:require-approval"            = 19786362
      "service-genai:tags"                        = 19786363
      "service-json-keys:commit-messages"         = 24847978
      "service-json-keys:master"                  = 6451910
      "service-json-keys:release-lines"           = 24853978
      "service-json-keys:require-approval"        = 7139127
      "service-json-keys:retired-lines"           = 26089011
      "service-json-keys:tags"                    = 18233582
      "service-narrative-engine:commit-messages"  = 24849296
      "service-narrative-engine:master"           = 12095747
      "service-narrative-engine:release-lines"    = 24854000
      "service-narrative-engine:require-approval" = 12095710
      "service-narrative-engine:tags"             = 18233590
      "service-template:commit-messages"          = 24847922
      "service-template:master"                   = 13476237
      "service-template:release-lines"            = 24853944
      "service-template:require-approval"         = 13476260
      "service-template:tags"                     = 18233578
    }
    "a-novel-kit" = {
      ".github:commit-messages"    = 24847779
      ".github:master"             = 17576434
      ".github:release-lines"      = 24853861
      ".github:require-approval"   = 17576470
      ".github:tags"               = 18233603
      "golib:commit-messages"      = 24847788
      "golib:master"               = 6984889
      "golib:release-lines"        = 24853872
      "golib:require-approval"     = 7138879
      "golib:tags"                 = 18233567
      "jwt:commit-messages"        = 24847813
      "jwt:master"                 = 3553643
      "jwt:release-lines"          = 24853888
      "jwt:require-approval"       = 7205681
      "jwt:retired-lines"          = 26088931
      "jwt:tags"                   = 18238255
      "nodelib:commit-messages"    = 24847794
      "nodelib:master"             = 6819228
      "nodelib:release-lines"      = 24853878
      "nodelib:require-approval"   = 7151857
      "nodelib:retired-lines"      = 26088933
      "nodelib:tags"               = 18233575
      "stack:commit-messages"      = 24847774
      "stack:master"               = 15613404
      "stack:release-lines"        = 25543416
      "stack:require-approval"     = 15613417
      "stack:retired-lines"        = 26088942
      "stack:tags"                 = 25543415
      "ui-assets:commit-messages"  = 25673546
      "ui-assets:master"           = 25673545
      "ui-assets:release-lines"    = 25673550
      "ui-assets:require-approval" = 25673548
      "ui-assets:tags"             = 25673549
      "uikit:commit-messages"      = 24847823
      "uikit:master"               = 19627229
      "uikit:release-lines"        = 24853904
      "uikit:require-approval"     = 19627232
      "uikit:tags"                 = 19627233
      "workflows:commit-messages"  = 24847845
      "workflows:master"           = 7205381
      "workflows:release-lines"    = 24853909
      "workflows:require-approval" = 7205548
      "workflows:retired-lines"    = 26088968
      "workflows:tags"             = 18233561
    }
  } : { "a-novel" = {}, "a-novel-kit" = {} }

  adopted_policies = var.adopt ? {
    "a-novel" = {
      ".github:governance:branch:master"                      = 63405131
      ".github:governance:branch:release/v*"                  = 63405133
      ".github:governance:tag:v*"                             = 63405134
      "infra:governance:branch:master"                        = 63405132
      "platform-studio:governance:branch:master"              = 63405142
      "platform-studio:governance:branch:release/v*"          = 63405145
      "platform-studio:governance:tag:v*"                     = 63405146
      "platform-studio:release:branch:master"                 = 62965453
      "platform-studio:release:branch:release/v*"             = 62965455
      "platform-studio:release:tag:v*"                        = 62965457
      "platform-template:governance:branch:master"            = 63405136
      "platform-template:governance:branch:release/v*"        = 63405137
      "platform-template:governance:tag:v*"                   = 63405140
      "platform-template:release:branch:master"               = 63641703
      "platform-template:release:branch:release/v*"           = 63641704
      "platform-template:release:tag:v*"                      = 63641705
      "service-authentication:governance:branch:master"       = 63405180
      "service-authentication:governance:branch:release/v*"   = 63405181
      "service-authentication:governance:tag:v*"              = 63405185
      "service-authentication:release:branch:master"          = 62965483
      "service-authentication:release:branch:release/v*"      = 62965485
      "service-authentication:release:tag:v*"                 = 62965490
      "service-genai:governance:branch:master"                = 63405184
      "service-genai:governance:branch:release/v*"            = 63405187
      "service-genai:governance:tag:v*"                       = 63405190
      "service-genai:release:branch:master"                   = 62965488
      "service-genai:release:branch:release/v*"               = 62965493
      "service-genai:release:tag:v*"                          = 62965497
      "service-json-keys:governance:branch:master"            = 63405176
      "service-json-keys:governance:branch:release/v*"        = 63405177
      "service-json-keys:governance:tag:v*"                   = 63405178
      "service-json-keys:release:branch:master"               = 62965486
      "service-json-keys:release:branch:release/v*"           = 62965491
      "service-json-keys:release:tag:v*"                      = 62965495
      "service-narrative-engine:governance:branch:master"     = 63405182
      "service-narrative-engine:governance:branch:release/v*" = 63405186
      "service-narrative-engine:governance:tag:v*"            = 63405188
      "service-narrative-engine:release:branch:master"        = 62965489
      "service-narrative-engine:release:branch:release/v*"    = 62965494
      "service-narrative-engine:release:tag:v*"               = 62965496
      "service-template:governance:branch:master"             = 63405139
      "service-template:governance:branch:release/v*"         = 63405141
      "service-template:governance:tag:v*"                    = 63405143
      "service-template:release:branch:master"                = 62965450
      "service-template:release:branch:release/v*"            = 62965451
      "service-template:release:tag:v*"                       = 62965452
    }
    "a-novel-kit" = {
      ".github:governance:branch:master"       = 63405077
      ".github:governance:branch:release/v*"   = 63405078
      ".github:governance:tag:v*"              = 63405079
      "golib:governance:branch:master"         = 63405081
      "golib:governance:branch:release/v*"     = 63405082
      "golib:governance:tag:v*"                = 63405084
      "golib:release:branch:master"            = 62965398
      "golib:release:branch:release/v*"        = 62965401
      "golib:release:tag:v*"                   = 62965404
      "jwt:governance:branch:master"           = 63405090
      "jwt:governance:branch:release/v*"       = 63405094
      "jwt:governance:tag:v*"                  = 63405097
      "jwt:release:branch:master"              = 62965395
      "jwt:release:branch:release/v*"          = 62965400
      "jwt:release:tag:v*"                     = 62965402
      "nodelib:governance:branch:master"       = 63405085
      "nodelib:governance:branch:release/v*"   = 63405089
      "nodelib:governance:tag:v*"              = 63405092
      "nodelib:release:branch:master"          = 62965396
      "nodelib:release:branch:release/v*"      = 62965399
      "nodelib:release:tag:v*"                 = 62965403
      "stack:governance:branch:master"         = 63405093
      "stack:governance:branch:release/v*"     = 63830980
      "stack:governance:tag:v*"                = 63830981
      "stack:release:branch:master"            = 62965391
      "stack:release:branch:release/v*"        = 63830976
      "stack:release:tag:v*"                   = 63830977
      "ui-assets:governance:branch:master"     = 64018520
      "ui-assets:governance:branch:release/v*" = 64018522
      "ui-assets:governance:tag:v*"            = 64018523
      "ui-assets:release:branch:master"        = 64018515
      "ui-assets:release:branch:release/v*"    = 64018517
      "ui-assets:release:tag:v*"               = 64018519
      "uikit:governance:branch:master"         = 63405091
      "uikit:governance:branch:release/v*"     = 63405095
      "uikit:governance:tag:v*"                = 63405096
      "uikit:release:branch:master"            = 62965390
      "uikit:release:branch:release/v*"        = 62965392
      "uikit:release:tag:v*"                   = 62965397
      "workflows:governance:branch:master"     = 63405126
      "workflows:governance:branch:release/v*" = 63405127
      "workflows:governance:tag:v*"            = 63405128
      "workflows:release:branch:master"        = 62965438
      "workflows:release:branch:release/v*"    = 62965440
      "workflows:release:tag:v*"               = 62965442
    }
  } : { "a-novel" = {}, "a-novel-kit" = {} }

  adopted_environments = { for owner, policies in local.adopted_policies : owner => toset([for key in keys(policies) : join(":", slice(split(":", key), 0, 2))]) }
  adopted_secrets      = { for owner, organization in var.organizations : owner => var.adopt ? organization.scoped_secrets : toset([]) }
}

# a-novel
import {
  for_each = local.adopted_rulesets["a-novel"]
  to       = module.a_novel.github_repository_ruleset.this[each.key]
  id       = "${split(":", each.key)[0]}:${each.value}"
}

import {
  for_each = local.adopted_environments["a-novel"]
  to       = module.a_novel.github_repository_environment.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_policies["a-novel"]
  to       = module.a_novel.github_repository_environment_deployment_policy.this[each.key]
  id       = "${join(":", slice(split(":", each.key), 0, 2))}:${each.value}"
}

import {
  for_each = local.adopted_secrets["a-novel"]
  to       = module.a_novel.github_actions_organization_secret_repositories.this[each.key]
  id       = each.key
}

# a-novel-kit
import {
  for_each = local.adopted_rulesets["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_ruleset.this[each.key]
  id       = "${split(":", each.key)[0]}:${each.value}"
}

import {
  for_each = local.adopted_environments["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_environment.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_policies["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_environment_deployment_policy.this[each.key]
  id       = "${join(":", slice(split(":", each.key), 0, 2))}:${each.value}"
}

import {
  for_each = local.adopted_secrets["a-novel-kit"]
  to       = module.a_novel_kit.github_actions_organization_secret_repositories.this[each.key]
  id       = each.key
}
