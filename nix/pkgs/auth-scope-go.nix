{
  buildGoModule,
}:
buildGoModule {
  pname = "auth-scope-eval-test-go";
  version = "0.1.0";
  src = ../../libs/go-libs/auth-scope-evaluator;
  vendorHash = null;
}
