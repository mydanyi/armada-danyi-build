# Personal Fedora build-deps image for the armada packages stage.
#
# Instead of resolving the whole Fedora 44 dependency set from the network on
# every run, this reuses the already-warmed toolchain layers of an existing
# local builder image (the gamescope Y700 one) passed in as BUILDER_PARENT.
#
# That parent image still carries a stale /src, /work and /tmp/packages from
# whatever was last built inside it. Those are removed in this new layer so a
# package stage can only ever see the current checkout's sources and RPMs --
# the parent's old sources/RPMs must never stand in for the new sources. The
# parent's own layers are untouched (the layer cache is fully preserved); only
# the paths this stage would otherwise shadow are cleared on top.
#
# rpm is capped at 8 parallel jobs to match the runner CPU budget.
ARG BUILDER_PARENT
FROM ${BUILDER_PARENT}

RUN if rpm -q terra-release >/dev/null 2>&1; then rpm -e --nodeps terra-release; fi \
    && rm -rf /tmp/packages /work /src \
    && mkdir -p /etc/rpm \
    && printf '%%_smp_build_ncpus 8\n%%_smp_mflags -j8\n' > /etc/rpm/macros.armada-personal-limit \
    && cat /etc/rpm/macros.armada-personal-limit
