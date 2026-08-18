{
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "auth-scope";
  version = "0.1.0";
  src = ../../.;
  cargoLock.lockFile = ../../Cargo.lock;
  doCheck = false;
}
