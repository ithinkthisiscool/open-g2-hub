"""HTTP routes of the hub, one module per feature. Each module exposes ROUTES, a list of
(method, path, handler) tuples that hub.app registers; the service functions the handlers use
(push_calendar, push_weather, push_news, ...) live next to them and are also called directly by
the background loops, the profile restore and the Even AI tools."""
# Note: hub/routes/diagnostics.py (/api/doctor, /api/diagnostics) is registered through core.ROUTES;
# /api/keys is in settings.ROUTES.
