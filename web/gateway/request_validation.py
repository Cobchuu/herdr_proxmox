"""Request validation failures tied to specific editable fields."""


class FieldValidationError(ValueError):
    def __init__(self, message, fields):
        super().__init__(message)
        self.field_errors = {field: message for field in fields}
