"""The dev world used for tuning is a different draw from the scored world (seed 42)."""

from eval.dev_world import build_dev_world


def test_dev_world_is_a_fresh_draw_with_the_same_typologies(tmp_path, world):
    from case_zero.world import World

    dev = World.load(build_dev_world(7, tmp_path / "dev"))
    dev_rings = {l["ring_id"] for l in dev.bundle.labels}
    main_rings = {l["ring_id"] for l in world.bundle.labels}
    assert dev_rings == main_rings  # same typologies and ring count
    dev_members = {(l["ring_id"], l["acct_id"]) for l in dev.bundle.labels if l["role"] != "victim" and l["ring_id"] != "ring_demo_otp"}
    main_members = {(l["ring_id"], l["acct_id"]) for l in world.bundle.labels if l["role"] != "victim" and l["ring_id"] != "ring_demo_otp"}
    assert len(dev_members & main_members) < len(main_members) // 4  # different accounts carry the rings
