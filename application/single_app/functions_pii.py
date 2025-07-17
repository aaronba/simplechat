# functions_pii.py

import re
import json
from typing import Dict, List, Tuple, Any
from functions_settings import get_settings
from functions_logging import add_file_task_to_file_processing_log


class PIIDetector:
    """
    PII (Personally Identifiable Information) detection and redaction functionality.
    Supports configurable detection and masking of various PII types.
    """
    
    def __init__(self):
        """Initialize PII patterns and redaction settings."""
        self.pii_patterns = {
            'email': {
                'pattern': r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b',
                'mask': '[EMAIL_REDACTED]',
                'description': 'Email addresses'
            },
            'phone': {
                'pattern': r'(?:\+?1[-.\s]?)?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b',
                'mask': '[PHONE_REDACTED]',
                'description': 'Phone numbers (US format)'
            },
            'ssn': {
                'pattern': r'\b\d{3}-?\d{2}-?\d{4}\b',
                'mask': '[SSN_REDACTED]',
                'description': 'Social Security Numbers'
            },
            'credit_card': {
                'pattern': r'\b(?:\d{4}[-\s]?){3}\d{4}\b',
                'mask': '[CC_REDACTED]',
                'description': 'Credit card numbers'
            },
            'ip_address': {
                'pattern': r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b',
                'mask': '[IP_REDACTED]',
                'description': 'IP addresses'
            },
            'name': {
                'pattern': r'\b[A-Z][a-z]+\s+[A-Z][a-z]+\b',
                'mask': '[NAME_REDACTED]',
                'description': 'Names (basic pattern)'
            },
            'driver_license': {
                'pattern': r'\b[A-Z]{1,2}\d{6,8}\b',
                'mask': '[DL_REDACTED]',
                'description': 'Driver license numbers (basic pattern)'
            },
            'date_of_birth': {
                'pattern': r'\b(?:0[1-9]|1[0-2])[/-](?:0[1-9]|[12]\d|3[01])[/-](?:19|20)\d{2}\b',
                'mask': '[DOB_REDACTED]',
                'description': 'Date of birth (MM/DD/YYYY format)'
            }
        }
    
    def get_enabled_pii_types(self) -> List[str]:
        """Get list of enabled PII types from settings."""
        settings = get_settings()
        if not settings.get('enable_pii_scrubbing', False):
            return []
        
        enabled_types = []
        for pii_type in self.pii_patterns.keys():
            if settings.get(f'pii_detect_{pii_type}', True):  # Default to enabled
                enabled_types.append(pii_type)
        
        return enabled_types
    
    def detect_pii(self, text: str) -> List[Dict[str, Any]]:
        """
        Detect PII in the given text.
        
        Args:
            text: Text to analyze for PII
            
        Returns:
            List of detected PII instances with type, position, and original value
        """
        if not text:
            return []
        
        enabled_types = self.get_enabled_pii_types()
        if not enabled_types:
            return []
        
        detections = []
        
        for pii_type in enabled_types:
            pattern = self.pii_patterns[pii_type]['pattern']
            matches = re.finditer(pattern, text, re.IGNORECASE)
            
            for match in matches:
                detections.append({
                    'type': pii_type,
                    'value': match.group(),
                    'start': match.start(),
                    'end': match.end(),
                    'description': self.pii_patterns[pii_type]['description']
                })
        
        # Sort by position to handle replacements correctly
        detections.sort(key=lambda x: x['start'], reverse=True)
        
        return detections
    
    def redact_pii(self, text: str) -> Tuple[str, List[Dict[str, Any]]]:
        """
        Redact PII from the given text.
        
        Args:
            text: Text to redact PII from
            
        Returns:
            Tuple of (redacted_text, list_of_redacted_items)
        """
        if not text:
            return text, []
        
        detections = self.detect_pii(text)
        if not detections:
            return text, []
        
        redacted_text = text
        redacted_items = []
        
        # Process detections in reverse order to maintain position accuracy
        for detection in detections:
            pii_type = detection['type']
            start = detection['start']
            end = detection['end']
            original_value = detection['value']
            mask = self.pii_patterns[pii_type]['mask']
            
            # Replace the PII with the mask
            redacted_text = redacted_text[:start] + mask + redacted_text[end:]
            
            redacted_items.append({
                'type': pii_type,
                'original_value': original_value,
                'masked_value': mask,
                'position': f"{start}-{end}",
                'description': detection['description']
            })
        
        return redacted_text, redacted_items
    
    def check_and_redact_content(self, content: str, context: str = "unknown") -> Dict[str, Any]:
        """
        Check content for PII and redact if enabled.
        
        Args:
            content: Content to check and potentially redact
            context: Context description for logging (e.g., "chat_message", "document_content")
            
        Returns:
            Dict containing:
                - original_content: Original text
                - redacted_content: Text with PII redacted
                - has_pii: Boolean indicating if PII was found
                - redacted_items: List of redacted PII items
                - enabled: Boolean indicating if PII scrubbing is enabled
        """
        settings = get_settings()
        pii_enabled = settings.get('enable_pii_scrubbing', False)
        
        result = {
            'original_content': content,
            'redacted_content': content,
            'has_pii': False,
            'redacted_items': [],
            'enabled': pii_enabled,
            'context': context
        }
        
        if not pii_enabled or not content:
            return result
        
        try:
            redacted_content, redacted_items = self.redact_pii(content)
            
            result.update({
                'redacted_content': redacted_content,
                'has_pii': len(redacted_items) > 0,
                'redacted_items': redacted_items
            })
            
        except Exception as e:
            print(f"Error during PII detection/redaction in {context}: {e}")
            # On error, return original content unchanged
            
        return result


def check_content_for_pii(content: str, context: str = "unknown") -> Dict[str, Any]:
    """
    Convenience function to check content for PII.
    
    Args:
        content: Content to check
        context: Context for logging
        
    Returns:
        Dict with PII check results
    """
    detector = PIIDetector()
    return detector.check_and_redact_content(content, context)


def log_pii_redaction(user_id: str, document_id: str = None, redaction_details: Dict = None):
    """
    Log PII redaction action for audit purposes.
    
    Args:
        user_id: ID of the user whose content was processed
        document_id: Optional document ID if this was document processing
        redaction_details: Details about what was redacted
    """
    try:
        from config import cosmos_safety_container
        import uuid
        from datetime import datetime
        
        if not redaction_details or not redaction_details.get('has_pii'):
            return  # Nothing to log
        
        log_entry = {
            'id': str(uuid.uuid4()),
            'type': 'pii_redaction',
            'user_id': user_id,
            'document_id': document_id,
            'timestamp': datetime.utcnow().isoformat(),
            'context': redaction_details.get('context', 'unknown'),
            'redacted_items_count': len(redaction_details.get('redacted_items', [])),
            'redacted_types': list(set([item['type'] for item in redaction_details.get('redacted_items', [])])),
            'action': 'pii_redacted',
            'status': 'completed',
            'metadata': {
                'redacted_items': redaction_details.get('redacted_items', []),
                'has_original_content': bool(redaction_details.get('original_content')),
                'content_length': len(redaction_details.get('original_content', ''))
            }
        }
        
        # Store in the same container as content safety logs
        cosmos_safety_container.upsert_item(log_entry)
        
        # Also add to file processing log if document_id is provided
        if document_id:
            add_file_task_to_file_processing_log(
                document_id=document_id,
                user_id=user_id,
                content=f"PII redaction completed: {len(redaction_details.get('redacted_items', []))} items redacted of types: {', '.join(log_entry['redacted_types'])}"
            )
        
    except Exception as e:
        print(f"Error logging PII redaction: {e}")


def get_pii_detection_summary() -> Dict[str, Any]:
    """
    Get summary of available PII detection types and settings.
    
    Returns:
        Dict with PII detection configuration info
    """
    detector = PIIDetector()
    settings = get_settings()
    
    return {
        'enabled': settings.get('enable_pii_scrubbing', False),
        'available_types': {
            pii_type: {
                'description': info['description'],
                'enabled': settings.get(f'pii_detect_{pii_type}', True),
                'mask': info['mask']
            }
            for pii_type, info in detector.pii_patterns.items()
        },
        'settings_prefix': 'pii_detect_'  # For admin UI to know how to name settings
    }