defmodule SymphonyElixir.Install.SecurityFileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Install.SecurityFile

  test "read/1 coerces quoted booleans and trims maintainers" do
    config_path = Path.join(tmp_dir!("install-security-file"), "siaan-security.yml")

    File.write!(
      config_path,
      """
      maintainers:
        - " alice "
        - bob
      setup:
        labels: "false"
        issue_restriction: collaborators_only
        branch_protection: "true"
      """
    )

    assert {:ok, config} = SecurityFile.read(config_path)

    assert config == %{
             maintainers: ["alice", "bob"],
             setup: %{
               labels: false,
               issue_restriction: "collaborators_only",
               branch_protection: true
             }
           }

    assert SecurityFile.render(config) =~ "labels: false"
    assert SecurityFile.render(config) =~ "branch_protection: true"
  end

  test "read/1 returns an error for invalid yaml" do
    config_path = Path.join(tmp_dir!("install-security-file-invalid-yaml"), "siaan-security.yml")
    File.write!(config_path, "maintainers: [alice\n")

    assert {:error, {:invalid_security_file, {:yaml_decode_failed, _reason}}} =
             SecurityFile.read(config_path)
  end

  test "read/1 returns an error for invalid setup booleans" do
    config_path = Path.join(tmp_dir!("install-security-file-invalid-bool"), "siaan-security.yml")

    File.write!(
      config_path,
      """
      setup:
        labels: null
        branch_protection: maybe
      """
    )

    assert {:error, {:invalid_security_file, {:invalid_boolean, "setup.labels", nil}}} =
             SecurityFile.read(config_path)
  end

  test "default/0 and read/1 surface filesystem and shape errors" do
    assert SecurityFile.default() == %{
             maintainers: [],
             setup: %{
               labels: true,
               issue_restriction: "collaborators_only",
               branch_protection: true
             }
           }

    directory_path = tmp_dir!("install-security-file-directory")

    assert {:error, {:security_file_read_failed, _reason}} =
             SecurityFile.read(directory_path)

    top_level_path = Path.join(tmp_dir!("install-security-file-top-level"), "siaan-security.yml")
    File.write!(top_level_path, "- alice\n- bob\n")

    assert {:error, {:invalid_security_file, {:invalid_top_level, ["alice", "bob"]}}} =
             SecurityFile.read(top_level_path)
  end

  test "read/1 rejects invalid maintainer, setup, boolean, and issue restriction values" do
    maintainer_path = Path.join(tmp_dir!("install-security-file-maintainer"), "siaan-security.yml")
    File.write!(maintainer_path, "maintainers:\n  - 123\n")

    assert {:error, {:invalid_security_file, {:invalid_maintainer, 123}}} =
             SecurityFile.read(maintainer_path)

    setup_path = Path.join(tmp_dir!("install-security-file-setup"), "siaan-security.yml")
    File.write!(setup_path, "setup: nope\n")

    assert {:error, {:invalid_security_file, {:invalid_setup, "nope"}}} =
             SecurityFile.read(setup_path)

    boolean_path = Path.join(tmp_dir!("install-security-file-bad-bool"), "siaan-security.yml")
    File.write!(boolean_path, "setup:\n  labels: maybe\n")

    assert {:error, {:invalid_security_file, {:invalid_boolean, "setup.labels", "maybe"}}} =
             SecurityFile.read(boolean_path)

    blank_issue_path = Path.join(tmp_dir!("install-security-file-blank-issue"), "siaan-security.yml")
    File.write!(blank_issue_path, "setup:\n  issue_restriction: \"   \"\n")

    assert {:error, {:invalid_security_file, {:invalid_issue_restriction, "   "}}} =
             SecurityFile.read(blank_issue_path)

    nonbinary_issue_path = Path.join(tmp_dir!("install-security-file-nonbinary-issue"), "siaan-security.yml")
    File.write!(nonbinary_issue_path, "setup:\n  issue_restriction: 123\n")

    assert {:error, {:invalid_security_file, {:invalid_issue_restriction, 123}}} =
             SecurityFile.read(nonbinary_issue_path)
  end
end
