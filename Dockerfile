# Odoo 18.0 Community — container image built from the source in this repo.
#
# Two stages: the builder compiles every Python dependency into wheels, the
# runtime installs those wheels next to the shared libraries they link against.
# Keeping the toolchain out of the final image saves roughly 500 MB.

# ---------------------------------------------------------------------------
# Stage 1 — build wheels
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Headers required to compile psycopg2, lxml, python-ldap, Pillow and libsass.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        libxml2-dev \
        libxslt1-dev \
        libldap2-dev \
        libsasl2-dev \
        libjpeg-dev \
        libfreetype6-dev \
        liblcms2-dev \
        libwebp-dev \
        libtiff-dev \
        libopenjp2-7-dev \
        zlib1g-dev \
        libssl-dev \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip wheel --wheel-dir=/wheels -r /tmp/requirements.txt

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    ODOO_RC=/etc/odoo/odoo.conf \
    ODOO_DATA_DIR=/var/lib/odoo \
    PATH="/opt/odoo:${PATH}"

# Runtime shared libraries only — no compilers.
#   fonts-noto-cjk  : CJK glyphs, without it Chinese text renders as boxes in PDFs
#   gosu            : drop from root to the odoo user after fixing volume ownership
#   postgresql-client: pg_isready / psql, used by the entrypoint
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fontconfig \
        fonts-noto-cjk \
        gosu \
        libfreetype6 \
        libjpeg62-turbo \
        liblcms2-2 \
        libldap-2.5-0 \
        libopenjp2-7 \
        libpq5 \
        libsasl2-2 \
        libtiff6 \
        libwebp7 \
        libxml2 \
        libxslt1.1 \
        postgresql-client \
        xz-utils \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Patched wkhtmltopdf (Qt build). Odoo's PDF reports need this exact fork —
# the plain Debian package renders headers and footers incorrectly.
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL -o /tmp/wkhtmltox.deb \
        "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_${arch}.deb"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb; \
    rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/*; \
    wkhtmltopdf --version

COPY --from=builder /wheels /wheels
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-index --find-links=/wheels -r /tmp/requirements.txt \
    && rm -rf /wheels /tmp/requirements.txt

RUN groupadd -r odoo && useradd -r -g odoo -d /var/lib/odoo -s /sbin/nologin odoo

COPY . /opt/odoo
RUN mkdir -p /etc/odoo /var/lib/odoo \
    && chown -R odoo:odoo /var/lib/odoo /etc/odoo \
    && chmod +x /opt/odoo/odoo-bin /opt/odoo/deploy/entrypoint.sh \
    && ln -s /opt/odoo/odoo-bin /usr/local/bin/odoo

VOLUME ["/var/lib/odoo"]
EXPOSE 8069

ENTRYPOINT ["/opt/odoo/deploy/entrypoint.sh"]
CMD ["odoo"]
